import Foundation
import SharesheetCore

/// Downloads the media of an X post: public posts from the syndication endpoint, protected posts from the
/// signed-in tweet page.
public struct XMediaLoader: Sendable {
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

    static let sessionProbeURL = URL(string: "https://x.com/settings/account")!

    private let fetcher: any ResourceFetching
    private let limits: Limits
    private let urlSession: URLSession
    private let diagnostics: Diagnostics?
    private let sessionProvider: (@Sendable () -> WebSession?)?

    public init(
        fetcher: any ResourceFetching, limits: Limits = Limits(),
        diagnostics: Diagnostics? = nil,
        session: (@Sendable () -> WebSession?)? = nil
    ) {
        self.init(
            fetcher: fetcher, limits: limits, configuration: .ephemeral,
            diagnostics: diagnostics, session: session)
    }

    init(
        fetcher: any ResourceFetching, limits: Limits, configuration: URLSessionConfiguration,
        diagnostics: Diagnostics? = nil,
        session: (@Sendable () -> WebSession?)? = nil
    ) {
        self.fetcher = fetcher
        self.limits = limits
        self.urlSession = URLSession(configuration: configuration)
        self.diagnostics = diagnostics
        self.sessionProvider = session
    }

    /// The caller owns the temporary folder in `files` and removes it after copying.
    public func download(for postURL: URL) async -> Download? {
        guard let id = XTweetID.string(from: postURL) else { return nil }
        var media: [XMediaItem] = []
        var caption: String?
        var failure: (stage: String, detail: String)?

        if let url = XSyndication.requestURL(for: id) {
            do {
                let data = try await fetcher.fetch(url).data
                let decoded = try XSyndication.decode(data)
                media = decoded.media
                caption = decoded.caption
                if media.isEmpty {
                    failure = ("syndication", "the post lists no images or videos")
                }
            } catch {
                failure = ("syndication", Self.describe(error))
            }
        } else {
            failure = ("syndication", "the post link could not be read")
        }

        if media.isEmpty, let session = sessionProvider?(), session.isUsable(requiredCookie: "auth_token") {
            do {
                let page = try await signedInPage(id: id, session: session)
                media = page.media
                if caption == nil { caption = page.caption }
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

    /// Checks whether X still accepts the stored session; never changes it.
    public func validateSession() async -> SessionStatus {
        await validateSession(probeURL: Self.sessionProbeURL)
    }

    /// Test seam; production uses `sessionProbeURL`.
    func validateSession(probeURL: URL) async -> SessionStatus {
        guard let session = sessionProvider?() else { return .noSession }
        guard session.isUsable(requiredCookie: "auth_token") else { return .expired }

        var request = URLRequest(url: probeURL)
        request.timeoutInterval = min(15, limits.fileTimeout)
        request.setValue(session.cookieHeader, forHTTPHeaderField: "Cookie")
        if let csrf = session.value(named: "ct0") {
            request.setValue(csrf, forHTTPHeaderField: "x-csrf-token")
        }
        request.setValue(Self.safariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("https://x.com/", forHTTPHeaderField: "Referer")

        guard let (data, response) = try? await urlSession.data(for: request),
              let http = response as? HTTPURLResponse
        else { return .unknown }
        if http.statusCode == 401 || http.statusCode == 403 || (300..<400).contains(http.statusCode)
            || http.url?.path.contains("/i/flow/login") == true
            || http.url?.path.hasPrefix("/login") == true {
            return .expired
        }
        guard (200..<300).contains(http.statusCode), let html = String(data: data, encoding: .utf8) else {
            return .unknown
        }
        if html.contains(#"action="/i/flow/login""#) || html.contains("<title>Log in") {
            return .expired
        }
        return .valid
    }

    private func signedInPage(
        id: String, session: WebSession
    ) async throws -> (media: [XMediaItem], caption: String?) {
        guard let url = URL(string: "https://x.com/i/status/\(id)") else { throw XPageError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = limits.fileTimeout
        request.setValue(session.cookieHeader, forHTTPHeaderField: "Cookie")
        if let csrf = session.value(named: "ct0") { request.setValue(csrf, forHTTPHeaderField: "x-csrf-token") }
        request.setValue(Self.safariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("https://x.com/", forHTTPHeaderField: "Referer")

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw XPageError.badResponse }
        if http.statusCode == 401 || http.statusCode == 403 || (300..<400).contains(http.statusCode)
            || http.url?.path.contains("/i/flow/login") == true || http.url?.path.hasPrefix("/login") == true {
            throw XPageError.expired(http.statusCode)
        }
        guard (200..<300).contains(http.statusCode), let html = String(data: data, encoding: .utf8) else {
            throw XPageError.status(http.statusCode)
        }
        do {
            return try XPageMedia.decode(html: html, tweetID: id)
        } catch {
            throw XPageError.unreadable
        }
    }

    private func download(
        media: [XMediaItem], caption: String?, postURL: URL, cookieHeader: String?
    ) async -> Download? {
        let media = Array(media.prefix(max(0, limits.maxItems)))
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "x-\(UUID().uuidString)", directoryHint: .isDirectory)
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
        _ item: XMediaItem, named name: String, to directory: URL, cookieHeader: String?
    ) async throws -> URL {
        var request = URLRequest(url: item.url)
        request.timeoutInterval = limits.fileTimeout
        if let cookieHeader, !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        let (location, response) = try await urlSession.download(for: request)
        defer { try? FileManager.default.removeItem(at: location) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw XDownloadError.status(http.statusCode)
        }
        let target = directory.appending(path: "\(name).\(extensionFor(item))")
        try FileManager.default.moveItem(at: location, to: target)
        return target
    }

    private enum XDownloadError: Error, CustomStringConvertible {
        case status(Int)
        var description: String {
            switch self {
            case .status(let code): "HTTP \(code)"
            }
        }
    }

    private enum XPageError: Error, CustomStringConvertible {
        case invalidURL
        case badResponse
        case expired(Int)
        case status(Int)
        case unreadable

        var description: String {
            switch self {
            case .invalidURL: "the post link could not be read"
            case .badResponse: "the signed-in page returned no HTTP response"
            case .expired(let code): "session expired (HTTP \(code))"
            case .status(let code): "HTTP \(code)"
            case .unreadable: "the signed-in page could not be read"
            }
        }
    }

    private func report(postURL: URL, stage: String, detail: String, media: [String]) async {
        guard let diagnostics else { return }
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        var lines = [
            "# Bug: X media download failed",
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
        if let error = error as? XSyndicationError { return "the syndication response could not be read" }
        if let error = error as? XPageMediaError { return "the signed-in page could not be read" }
        if let error = error as? XPageError { return error.description }
        return String(describing: error)
    }

    private func extensionFor(_ item: XMediaItem) -> String {
        let ext = item.url.pathExtension.lowercased().filter { $0.isLetter || $0.isNumber }
        if !ext.isEmpty { return ext }
        return item.kind == .video ? "mp4" : "jpg"
    }
}
