import Foundation
import SharesheetCore

/// Lädt die Medien eines öffentlichen Beitrags in einen neuen temporären Ordner.
public struct InstagramMediaLoader: Sendable {
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

    public init(fetcher: any ResourceFetching, limits: Limits = Limits()) {
        self.init(fetcher: fetcher, limits: limits, configuration: .ephemeral)
    }

    /// Testnaht: `configuration` kann Stub-Protokollklassen tragen.
    init(fetcher: any ResourceFetching, limits: Limits, configuration: URLSessionConfiguration) {
        self.fetcher = fetcher
        self.limits = limits
        self.session = URLSession(configuration: configuration)
    }

    /// Der Aufrufer besitzt den temporären Ordner von `files` und löscht ihn nach dem Kopieren.
    public func download(for postURL: URL) async -> Download? {
        guard let embedURL = InstagramPost.embedURL(for: postURL),
              let result = try? await fetcher.fetch(embedURL),
              let html = String(data: result.data, encoding: .utf8),
              let post = try? InstagramPost.decode(embedHTML: html)
        else { return nil }

        let media = Array(post.media.prefix(max(0, limits.maxItems)))
        guard !media.isEmpty else { return nil }

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "instagram-\(UUID().uuidString)", directoryHint: .isDirectory)
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil
        else { return nil }

        var files: [URL] = []
        var total = 0
        for item in media {
            guard let file = await download(item, named: "\(files.count + 1)", to: directory) else { continue }
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            guard size <= limits.maxFileBytes, total + size <= limits.totalBytes else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            total += size
            files.append(file)
        }

        guard !files.isEmpty else {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        return Download(files: files, caption: post.caption)
    }

    private func download(_ item: InstagramPost.Media, named name: String, to directory: URL) async -> URL? {
        var request = URLRequest(url: item.url)
        request.timeoutInterval = limits.fileTimeout
        guard let (location, response) = try? await session.download(for: request) else { return nil }
        defer { try? FileManager.default.removeItem(at: location) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        let target = directory.appending(path: "\(name).\(extensionFor(item))")
        guard (try? FileManager.default.moveItem(at: location, to: target)) != nil else { return nil }
        return target
    }

    private func extensionFor(_ item: InstagramPost.Media) -> String {
        let ext = item.url.pathExtension.lowercased().filter { $0.isLetter || $0.isNumber }
        if !ext.isEmpty { return ext }
        return item.kind == .video ? "mp4" : "jpg"
    }
}
