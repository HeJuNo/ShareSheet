import Foundation
import SharesheetCore

/// Lädt die Medien eines öffentlichen Beitrags in einen neuen temporären Ordner.
public struct InstagramMediaLoader: Sendable {
    /// Receives a Markdown report on any failed or partial download; nil disables reporting.
    public typealias Diagnostics = @Sendable (String) async -> Void

    public struct Download: Equatable, Sendable {
        public var files: [URL]
        public var caption: String?

        public init(files: [URL], caption: String? = nil) {
            self.files = files
            self.caption = caption
        }
    }

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
    private let session: URLSession
    private let diagnostics: Diagnostics?

    public init(fetcher: any ResourceFetching, limits: Limits = Limits(), diagnostics: Diagnostics? = nil) {
        self.init(fetcher: fetcher, limits: limits, configuration: .ephemeral, diagnostics: diagnostics)
    }

    /// Testnaht: `configuration` kann Stub-Protokollklassen tragen.
    init(
        fetcher: any ResourceFetching, limits: Limits, configuration: URLSessionConfiguration,
        diagnostics: Diagnostics? = nil
    ) {
        self.fetcher = fetcher
        self.limits = limits
        self.session = URLSession(configuration: configuration)
        self.diagnostics = diagnostics
    }

    /// Der Aufrufer besitzt den temporären Ordner von `files` und löscht ihn nach dem Kopieren.
    /// Jeder Fehlschlag und jede teilweise fehlende Datei erzeugt einen Diagnosebericht.
    public func download(for postURL: URL) async -> Download? {
        guard let embedURL = InstagramPost.embedURL(for: postURL) else { return nil }

        let data: Data
        do {
            data = try await fetcher.fetch(embedURL).data
        } catch {
            await report(postURL: postURL, embedURL: embedURL, stage: "fetch embed page",
                         detail: Self.describe(error), media: [])
            return nil
        }
        guard let html = String(data: data, encoding: .utf8) else {
            await report(postURL: postURL, embedURL: embedURL, stage: "read embed page",
                         detail: "the page is not UTF-8 (\(data.count) bytes)", media: [])
            return nil
        }
        let post: InstagramPost.Post
        do {
            post = try InstagramPost.decode(embedHTML: html)
        } catch {
            await report(postURL: postURL, embedURL: embedURL, stage: "decode contextJSON",
                         detail: Self.describe(error), media: [])
            return nil
        }

        let media = Array(post.media.prefix(max(0, limits.maxItems)))
        guard !media.isEmpty else {
            await report(postURL: postURL, embedURL: embedURL, stage: "read media list",
                         detail: "the embed page lists no images or videos", media: [])
            return nil
        }

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
        return Download(files: files, caption: post.caption)
    }

    private func download(_ item: InstagramPost.Media, named name: String, to directory: URL) async throws -> URL {
        var request = URLRequest(url: item.url)
        request.timeoutInterval = limits.fileTimeout
        let (location, response) = try await session.download(for: request)
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
        return String(describing: error)
    }

    private func extensionFor(_ item: InstagramPost.Media) -> String {
        let ext = item.url.pathExtension.lowercased().filter { $0.isLetter || $0.isNumber }
        if !ext.isEmpty { return ext }
        return item.kind == .video ? "mp4" : "jpg"
    }
}
