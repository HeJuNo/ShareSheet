import Foundation
import SharesheetCore

/// Downloads what Spotify publishes for a track: its cover and the official preview clip.
/// Spotify streams full songs DRM-protected, so no full track is available.
public struct SpotifyMediaLoader: Sendable {
    public typealias Diagnostics = @Sendable (String) async -> Void
    public typealias Download = MediaDownload

    public struct Limits: Sendable {
        public var maxFileBytes: Int
        public var totalBytes: Int
        public var fileTimeout: TimeInterval

        public init(maxFileBytes: Int = 50_000_000, totalBytes: Int = 100_000_000, fileTimeout: TimeInterval = 60) {
            self.maxFileBytes = maxFileBytes
            self.totalBytes = totalBytes
            self.fileTimeout = fileTimeout
        }
    }

    private let fetcher: any ResourceFetching
    private let limits: Limits
    private let urlSession: URLSession
    private let diagnostics: Diagnostics?

    public init(
        fetcher: any ResourceFetching, limits: Limits = Limits(), diagnostics: Diagnostics? = nil
    ) {
        self.init(fetcher: fetcher, limits: limits, configuration: .ephemeral, diagnostics: diagnostics)
    }

    init(
        fetcher: any ResourceFetching, limits: Limits, configuration: URLSessionConfiguration,
        diagnostics: Diagnostics? = nil
    ) {
        self.fetcher = fetcher
        self.limits = limits
        self.urlSession = URLSession(configuration: configuration)
        self.diagnostics = diagnostics
    }

    /// The caller owns the temporary folder in `files` and removes it after copying.
    public func download(for trackURL: URL) async -> Download? {
        guard let id = SpotifyTrackID.string(from: trackURL),
              let pageURL = URL(string: "https://open.spotify.com/embed/track/\(id)")
        else { return nil }

        let decoded: (media: [SpotifyMediaItem], caption: String?)
        do {
            let data = try await fetcher.fetch(pageURL).data
            decoded = try SpotifyEmbed.decode(html: String(decoding: data, as: UTF8.self))
        } catch {
            await report(trackURL: trackURL, stage: "embed page", detail: Self.describe(error), files: [])
            return nil
        }
        guard !decoded.media.isEmpty else {
            await report(trackURL: trackURL, stage: "embed page",
                         detail: "the track lists no cover or preview", files: [])
            return nil
        }

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "spotify-\(UUID().uuidString)", directoryHint: .isDirectory)
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil
        else {
            await report(trackURL: trackURL, stage: "create temporary folder", detail: directory.path, files: [])
            return nil
        }

        var files: [URL] = []
        var failures: [String] = []
        var total = 0
        for item in decoded.media {
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
            await report(trackURL: trackURL, stage: "download media",
                         detail: "\(failures.count) of \(decoded.media.count) failed", files: failures)
        }
        guard !files.isEmpty else {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        return MediaDownload(files: files, caption: decoded.caption)
    }

    private func download(_ item: SpotifyMediaItem, named name: String, to directory: URL) async throws -> URL {
        var request = URLRequest(url: item.url)
        request.timeoutInterval = limits.fileTimeout
        let (location, response) = try await urlSession.download(for: request)
        defer { try? FileManager.default.removeItem(at: location) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SpotifyDownloadError.status(http.statusCode)
        }
        let target = directory.appending(path: "\(name).\(item.kind == .audio ? "mp3" : "jpg")")
        try FileManager.default.moveItem(at: location, to: target)
        return target
    }

    private enum SpotifyDownloadError: Error, CustomStringConvertible {
        case status(Int)
        var description: String {
            switch self {
            case .status(let code): "HTTP \(code)"
            }
        }
    }

    private func report(trackURL: URL, stage: String, detail: String, files: [String]) async {
        guard let diagnostics else { return }
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        var lines = [
            "# Bug: Spotify media download failed",
            "",
            "- When: \(ISO8601DateFormatter().string(from: Date()))",
            "- Track: \(trackURL.absoluteString)",
            "- Stage: \(stage)",
            "- Detail: \(detail)",
            "- App: \(version) (\(build)), iOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
        ]
        if !files.isEmpty {
            lines.append("- Media:")
            lines.append(contentsOf: files.map { "  - \($0)" })
        }
        await diagnostics(lines.joined(separator: "\n") + "\n")
    }

    private static func describe(_ error: any Error) -> String {
        if let error = error as? URLError { return "\(error.code.rawValue) \(error.localizedDescription)" }
        if error is SpotifyEmbedError { return "the embed page could not be read" }
        if let error = error as? SpotifyDownloadError { return error.description }
        return String(describing: error)
    }
}
