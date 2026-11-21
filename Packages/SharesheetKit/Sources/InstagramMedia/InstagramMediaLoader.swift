import Foundation
import SharesheetCore

/// Lädt die Medien eines Beitrags in einen neuen temporären Ordner: zuerst anonym, bei fehlenden
/// Medien und vorhandener Sitzung über den angemeldeten Web-Endpunkt.
public struct InstagramMediaLoader: Sendable {
    /// Receives a Markdown report on any failed or partial download; nil disables reporting.
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

    private let fetcher: any ResourceFetching
    private let limits: Limits
    private let urlSession: URLSession
    private let diagnostics: Diagnostics?
    /// Read lazily so a session saved after the loader was built is picked up.
    private let sessionProvider: (@Sendable () -> InstagramSession?)?

    public init(
        fetcher: any ResourceFetching, limits: Limits = Limits(),
        diagnostics: Diagnostics? = nil,
        session: (@Sendable () -> InstagramSession?)? = nil
    ) {
        self.init(
            fetcher: fetcher, limits: limits, configuration: .ephemeral,
            diagnostics: diagnostics, session: session)
    }

    /// Testnaht: `configuration` kann Stub-Protokollklassen tragen.
    init(
        fetcher: any ResourceFetching, limits: Limits, configuration: URLSessionConfiguration,
        diagnostics: Diagnostics? = nil,
        session: (@Sendable () -> InstagramSession?)? = nil
    ) {
        self.fetcher = fetcher
        self.limits = limits
        self.urlSession = URLSession(configuration: configuration)
        self.diagnostics = diagnostics
        self.sessionProvider = session
    }

    /// Der Aufrufer besitzt den temporären Ordner von `files` und löscht ihn nach dem Kopieren.
    /// Jeder Fehlschlag und jede teilweise fehlende Datei erzeugt einen Diagnosebericht.
    public func download(for postURL: URL) async -> Download? {
        guard let embedURL = InstagramPost.embedURL(for: postURL),
              let shortcode = InstagramPost.shortcode(in: postURL)
        else { return nil }

        var media: [InstagramPost.Media] = []
        var caption: String?
        var anonymousFailure: AnonymousFailure?

        do {
            let data = try await fetcher.fetch(embedURL).data
            guard let html = String(data: data, encoding: .utf8) else {
                anonymousFailure = AnonymousFailure(
                    stage: "read embed page", detail: "the page is not UTF-8 (\(data.count) bytes)")
                return await finish(
                    postURL: postURL, embedURL: embedURL, shortcode: shortcode,
                    media: media, caption: caption, anonymousFailure: anonymousFailure)
            }
            let post = try InstagramPost.decode(embedHTML: html)
            media = post.media
            caption = post.caption
            if media.isEmpty {
                anonymousFailure = AnonymousFailure(
                    stage: "read media list", detail: "the embed page lists no images or videos")
            }
        } catch {
            let stage = error is InstagramPost.DecodeError ? "decode contextJSON" : "fetch embed page"
            anonymousFailure = AnonymousFailure(stage: stage, detail: Self.describe(error))
        }

        return await finish(
            postURL: postURL, embedURL: embedURL, shortcode: shortcode,
            media: media, caption: caption, anonymousFailure: anonymousFailure)
    }

    private struct AnonymousFailure {
        var stage: String
        var detail: String
    }

    private func finish(
        postURL: URL, embedURL: URL, shortcode: String,
        media: [InstagramPost.Media], caption: String?, anonymousFailure: AnonymousFailure?
    ) async -> Download? {
        var media = media
        var caption = caption
        var anonymousFailure = anonymousFailure
        let storedSession = sessionProvider?()

        if media.isEmpty, let session = storedSession, session.isUsable(requiredCookie: "sessionid") {
            do {
                let signed = try await signedInMedia(shortcode: shortcode, session: session)
                media = signed.media
                if let signedCaption = signed.caption { caption = signedCaption }
                if media.isEmpty {
                    anonymousFailure = AnonymousFailure(
                        stage: "read media list", detail: "the signed-in API returned no images or videos")
                }
            } catch {
                let earlier = anonymousFailure.map { "\($0.stage): \($0.detail); then " } ?? ""
                await report(postURL: postURL, embedURL: embedURL, stage: "signed-in media API",
                             detail: earlier + Self.describe(error), media: [])
                return nil
            }
        }

        if media.isEmpty, let storedSession, !storedSession.isUsable(requiredCookie: "sessionid") {
            anonymousFailure = AnonymousFailure(
                stage: anonymousFailure?.stage ?? "read media list",
                detail: [anonymousFailure?.detail, "the stored Instagram session has expired"]
                    .compactMap { $0 }.joined(separator: "; "))
        }
        guard !media.isEmpty else {
            if let anonymousFailure {
                await report(postURL: postURL, embedURL: embedURL, stage: anonymousFailure.stage,
                             detail: anonymousFailure.detail, media: [])
            }
            return nil
        }
        return await download(media: media, caption: caption, postURL: postURL, embedURL: embedURL)
    }

    private func download(
        media: [InstagramPost.Media], caption: String?, postURL: URL, embedURL: URL
    ) async -> Download? {
        let media = Array(media.prefix(max(0, limits.maxItems)))
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "instagram-\(UUID().uuidString)", directoryHint: .isDirectory)
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil
        else {
            await report(postURL: postURL, embedURL: embedURL, stage: "create temporary folder",
                         detail: directory.path, media: [])
            return nil
        }

        var files: [URL] = []
        var failures: [String] = []
        var total = 0
        for item in media {
            do {
                let file = try await download(item, named: "\(files.count + 1)", to: directory)
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
            await report(postURL: postURL, embedURL: embedURL, stage: "download media",
                         detail: "\(failures.count) of \(media.count) failed", media: failures)
        }
        guard !files.isEmpty else {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        return Download(files: files, caption: caption)
    }

    private func signedInMedia(
        shortcode: String, session: InstagramSession
    ) async throws -> (media: [InstagramPost.Media], caption: String?) {
        guard let id = InstagramMediaID.string(for: shortcode),
              let url = URL(string: "https://www.instagram.com/api/v1/media/\(id)/info/")
        else { throw SignedInError.invalidID }

        var request = URLRequest(url: url)
        request.timeoutInterval = limits.fileTimeout
        request.setValue(session.cookieHeader, forHTTPHeaderField: "Cookie")
        if let csrf = session.value(named: "csrftoken") { request.setValue(csrf, forHTTPHeaderField: "X-CSRFToken") }
        request.setValue("936619743392459", forHTTPHeaderField: "X-IG-App-ID")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("https://www.instagram.com/p/\(shortcode)/", forHTTPHeaderField: "Referer")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SignedInError.badResponse }
        if http.statusCode == 401 || http.statusCode == 403 || (300..<400).contains(http.statusCode)
            || http.url?.path.contains("/accounts/login") == true {
            throw SignedInError.expired(http.statusCode)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SignedInError.status(http.statusCode)
        }
        do {
            return try InstagramAPI.decode(data)
        } catch {
            throw SignedInError.api(Self.describe(error))
        }
    }

    private func download(_ item: InstagramPost.Media, named name: String, to directory: URL) async throws -> URL {
        var request = URLRequest(url: item.url)
        request.timeoutInterval = limits.fileTimeout
        let (location, response) = try await urlSession.download(for: request)
        defer { try? FileManager.default.removeItem(at: location) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DownloadError.status(http.statusCode)
        }
        let target = directory.appending(path: "\(name).\(extensionFor(item))")
        try FileManager.default.moveItem(at: location, to: target)
        return target
    }

    private enum DownloadError: Error, CustomStringConvertible {
        case status(Int)
        var description: String {
            switch self {
            case .status(let code): "HTTP \(code)"
            }
        }
    }

    private enum SignedInError: Error, CustomStringConvertible {
        case invalidID
        case badResponse
        case expired(Int)
        case status(Int)
        case api(String)

        var description: String {
            switch self {
            case .invalidID: "the post shortcode could not be converted to a media id"
            case .badResponse: "the signed-in request returned no HTTP response"
            case .expired(let code): "session expired (HTTP \(code))"
            case .status(let code): "HTTP \(code)"
            case .api(let detail): detail
            }
        }
    }

    private func report(postURL: URL, embedURL: URL, stage: String, detail: String, media: [String]) async {
        guard let diagnostics else { return }
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        var lines = [
            "# Bug: Instagram media download failed",
            "",
            "- When: \(ISO8601DateFormatter().string(from: Date()))",
            "- Post: \(postURL.absoluteString)",
            "- Embed page: \(embedURL.absoluteString)",
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
        if let error = error as? URLError {
            return "\(error.code.rawValue) \(error.localizedDescription)"
        }
        if let error = error as? InstagramPost.DecodeError {
            switch error {
            case .missingContext: return "the embed page has no contextJSON"
            case .unreadable: return "contextJSON could not be decoded"
            }
        }
        if let error = error as? InstagramAPIError {
            switch error {
            case .noItems(let message): return "the signed-in API returned no media (\(message))"
            case .unreadable: return "the signed-in API response could not be read"
            }
        }
        if let error = error as? SignedInError { return error.description }
        return String(describing: error)
    }

    private func extensionFor(_ item: InstagramPost.Media) -> String {
        let ext = item.url.pathExtension.lowercased().filter { $0.isLetter || $0.isNumber }
        if !ext.isEmpty { return ext }
        return item.kind == .video ? "mp4" : "jpg"
    }
}
