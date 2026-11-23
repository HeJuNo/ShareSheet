import Foundation
import SharesheetCore

/// Downloads a Facebook post's photos or video: the public page first, then the signed-in page.
public struct FacebookMediaLoader: Sendable {
    public typealias Diagnostics = @Sendable (String) async -> Void
    public typealias Download = MediaDownload

    public struct Limits: Sendable {
        public var maxItems: Int
        public var maxFileBytes: Int
        public var totalBytes: Int
        public var fileTimeout: TimeInterval

        public init(
            maxItems: Int = 20, maxFileBytes: Int = 250_000_000,
            totalBytes: Int = 500_000_000, fileTimeout: TimeInterval = 60
        ) {
            self.maxItems = maxItems
            self.maxFileBytes = maxFileBytes
            self.totalBytes = totalBytes
            self.fileTimeout = fileTimeout
        }
    }

    private static let safariUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    static let sessionProbeURL = URL(string: "https://m.facebook.com/me")!

    private let limits: Limits
    private let urlSession: URLSession
    private let diagnostics: Diagnostics?
    private let sessionProvider: (@Sendable () -> WebSession?)?

    public init(
        limits: Limits = Limits(), diagnostics: Diagnostics? = nil,
        session: (@Sendable () -> WebSession?)? = nil
    ) {
        self.init(limits: limits, configuration: .ephemeral, diagnostics: diagnostics, session: session)
    }

    init(
        limits: Limits, configuration: URLSessionConfiguration, diagnostics: Diagnostics? = nil,
        session: (@Sendable () -> WebSession?)? = nil
    ) {
        self.limits = limits
        self.urlSession = URLSession(configuration: configuration)
        self.diagnostics = diagnostics
        self.sessionProvider = session
    }

    /// The caller owns the temporary folder in `files` and removes it after copying.
    public func download(for postURL: URL) async -> Download? {
        guard SocialEmbed.platform(of: postURL) == .facebook else { return nil }
        var media: [FacebookMediaItem] = []
        var caption: String?
        var failure: (stage: String, detail: String)?

        do {
            let page = try await fetch(postURL, session: nil, signedIn: false)
            let decoded = try FacebookPageMedia.decode(html: page.html)
            media = decoded.media
            caption = decoded.caption
            if media.isEmpty { failure = ("page", "the post lists no images or videos") }
        } catch {
            failure = ("page", Self.describe(error))
        }

        if media.isEmpty, let session = sessionProvider?(), session.isUsable(requiredCookie: "c_user") {
            do {
                let page = try await fetch(postURL, session: session, signedIn: true)
                let decoded = try FacebookPageMedia.decode(html: page.html)
                media = decoded.media
                if caption == nil { caption = decoded.caption }
                guard !media.isEmpty else {
                    await report(postURL: postURL, stage: "signed-in page",
                                 detail: "the page lists no images or videos", media: [])
                    return nil
                }
                return await download(media: media, caption: caption, postURL: postURL,
                                      cookieHeader: session.cookieHeader)
            } catch {
                let earlier = failure.map { "\($0.stage): \($0.detail); then " } ?? ""
                await report(postURL: postURL, stage: "signed-in page",
                             detail: earlier + Self.describe(error), media: [])
                return nil
            }
        }

        guard !media.isEmpty else {
            if let failure {
                await report(postURL: postURL, stage: failure.stage, detail: failure.detail, media: [])
            }
            return nil
        }
        return await download(media: media, caption: caption, postURL: postURL, cookieHeader: nil)
    }

    /// Checks whether Facebook still accepts the stored session; never changes it.
    public func validateSession() async -> SessionStatus {
        await validateSession(probeURL: Self.sessionProbeURL)
    }

    /// Test seam; production uses `sessionProbeURL`.
    func validateSession(probeURL: URL) async -> SessionStatus {
        guard let session = sessionProvider?() else { return .noSession }
        guard session.isUsable(requiredCookie: "c_user") else { return .expired }

        var request = URLRequest(url: probeURL)
        request.timeoutInterval = min(15, limits.fileTimeout)
        request.setValue(session.cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(Self.safariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("https://m.facebook.com/", forHTTPHeaderField: "Referer")

        guard let (data, response) = try? await urlSession.data(for: request),
              let http = response as? HTTPURLResponse
        else { return .unknown }
        let finalURL = response.url ?? probeURL
        if http.statusCode == 401 || http.statusCode == 403 || Self.isLoginURL(finalURL) {
            return .expired
        }
        guard (200..<300).contains(http.statusCode) else { return .unknown }
        if Self.isLoginPage(data) { return .expired }
        return .valid
    }

    private func fetch(
        _ postURL: URL, session: WebSession?, signedIn: Bool
    ) async throws -> (html: String, finalURL: URL) {
        var request = URLRequest(url: postURL)
        request.timeoutInterval = limits.fileTimeout
        if let session { request.setValue(session.cookieHeader, forHTTPHeaderField: "Cookie") }
        request.setValue(Self.safariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("https://www.facebook.com/", forHTTPHeaderField: "Referer")

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FacebookPageError.badResponse }
        let finalURL = response.url ?? postURL
        if signedIn, http.statusCode == 401 || http.statusCode == 403
            || Self.isLoginURL(finalURL) || Self.isLoginPage(data) {
            throw FacebookPageError.expired
        }
        guard (200..<300).contains(http.statusCode), let html = String(data: data, encoding: .utf8) else {
            throw FacebookPageError.status(http.statusCode)
        }
        return (html, finalURL)
    }

    private static func isLoginURL(_ url: URL) -> Bool {
        let path = url.path().lowercased()
        return path.contains("/login") || path.contains("/checkpoint")
    }

    private static func isLoginPage(_ data: Data) -> Bool {
        guard let html = String(data: data, encoding: .utf8) else { return true }
        return html.contains("id=\"login_form\"") || html.contains("<title>Log in") || html.contains("<title>Log into Facebook")
    }

    private func download(
        media: [FacebookMediaItem], caption: String?, postURL: URL, cookieHeader: String?
    ) async -> Download? {
        let media = Array(media.prefix(max(0, limits.maxItems)))
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "facebook-\(UUID().uuidString)", directoryHint: .isDirectory)
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil
        else {
            await report(postURL: postURL, stage: "create temporary folder", detail: directory.path, media: [])
            return nil
        }

        var files: [URL] = []
        var failures: [String] = []
        var total = 0
        for item in media {
            do {
                let file = try await download(item, named: "\(files.count + 1)", to: directory,
                                              cookieHeader: cookieHeader)
                let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
                let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
                guard size <= limits.maxFileBytes else {
                    try? FileManager.default.removeItem(at: file)
                    failures.append("\(item.url.absoluteString): \(size) bytes over the \(limits.maxFileBytes) byte limit")
                    continue
                }
                guard total + size <= limits.totalBytes else {
                    try? FileManager.default.removeItem(at: file)
                    failures.append("\(item.url.absoluteString): exceeds the \(limits.totalBytes) byte total")
                    continue
                }
                total += size
                files.append(file)
            } catch {
                failures.append("\(item.url.absoluteString): \(Self.describe(error))")
            }
        }

        if !failures.isEmpty {
            await report(postURL: postURL, stage: "download media",
                         detail: "\(failures.count) of \(media.count) failed", media: failures)
        }
        guard !files.isEmpty else {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        return MediaDownload(files: files, caption: caption)
    }

    private func download(
        _ item: FacebookMediaItem, named name: String, to directory: URL, cookieHeader: String?
    ) async throws -> URL {
        var request = URLRequest(url: item.url)
        request.timeoutInterval = limits.fileTimeout
        if let cookieHeader, !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        let (location, response) = try await urlSession.download(for: request)
        defer { try? FileManager.default.removeItem(at: location) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FacebookDownloadError.status(http.statusCode)
        }
        let ext = item.url.pathExtension.lowercased().filter { $0.isLetter || $0.isNumber }
        let target = directory.appending(
            path: "\(name).\(ext.isEmpty ? (item.kind == .video ? "mp4" : "jpg") : ext)")
        try FileManager.default.moveItem(at: location, to: target)
        return target
    }

    private enum FacebookDownloadError: Error, CustomStringConvertible {
        case status(Int)
        var description: String {
            switch self {
            case .status(let code): "HTTP \(code)"
            }
        }
    }

    private enum FacebookPageError: Error, CustomStringConvertible {
        case badResponse
        case expired
        case status(Int)

        var description: String {
            switch self {
            case .badResponse: "the page returned no HTTP response"
            case .expired: "session expired"
            case .status(let code): "HTTP \(code)"
            }
        }
    }

    private func report(postURL: URL, stage: String, detail: String, media: [String]) async {
        guard let diagnostics else { return }
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        var lines = [
            "# Bug: Facebook media download failed",
            "",
            "- When: \(ISO8601DateFormatter().string(from: Date()))",
            "- Post: \(postURL.absoluteString)",
            "- Stage: \(stage)",
            "- Detail: \(detail)",
            "- App: \(version) (\(build)), iOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
        ]
        if !media.isEmpty {
            lines.append("- Media:")
            lines.append(contentsOf: media.map { "  - \($0)" })
        }
        await diagnostics(lines.joined(separator: "\n") + "\n")
    }

    private static func describe(_ error: any Error) -> String {
        if let error = error as? URLError { return "\(error.code.rawValue) \(error.localizedDescription)" }
        if let error = error as? FacebookPageError { return error.description }
        if let error = error as? FacebookDownloadError { return error.description }
        return String(describing: error)
    }
}
