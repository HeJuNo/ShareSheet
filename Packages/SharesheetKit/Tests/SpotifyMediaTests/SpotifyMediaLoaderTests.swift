import Foundation
import Testing
import SharesheetCore
@testable import SpotifyMedia

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]

    static func serve(_ url: String, _ reply: Reply) {
        lock.withLock { replies[url] = reply }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let reply = Self.lock.withLock({ Self.replies[url.absoluteString] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class FetchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL] = []

    var urls: [URL] { lock.withLock { _urls } }
    func record(_ url: URL) { lock.withLock { _urls.append(url) } }
}

private struct StubFetcher: ResourceFetching {
    let body: String?
    let recorder: FetchRecorder?

    init(body: String?, recorder: FetchRecorder? = nil) {
        self.body = body
        self.recorder = recorder
    }

    func fetch(_ url: URL) async throws -> (data: Data, mimeType: String?) {
        recorder?.record(url)
        guard let body else { throw URLError(.badServerResponse) }
        return (Data(body.utf8), "text/html")
    }
}

private final class ReportSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _reports: [String] = []

    var reports: [String] { lock.withLock { _reports } }
    func record(_ report: String) { lock.withLock { _reports.append(report) } }
}

private func page(entity: String) -> String {
    let next = #"""
    {"props":{"pageProps":{"state":{"data":{"entity":\#(entity)}}}}}
    """#
    return "<html><body><script id=\"__NEXT_DATA__\" type=\"application/json\">\(next)</script></body></html>"
}

private let trackURL = URL(string: "https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT")!

private func loader(
    _ html: String?, limits: SpotifyMediaLoader.Limits = .init(),
    diagnostics: SpotifyMediaLoader.Diagnostics? = nil, recorder: FetchRecorder? = nil
) -> SpotifyMediaLoader {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return SpotifyMediaLoader(
        fetcher: StubFetcher(body: html, recorder: recorder), limits: limits, configuration: configuration,
        diagnostics: diagnostics)
}

private func entity(
    cover: Bool = true, coverURL: String = "https://image-cdn-fa.spotifycdn.com/image/ab67616d00001e02",
    preview: Bool = true, previewURL: String = "https://p.scdn.co/mp3-preview/40a780b2"
) -> String {
    var parts = [#""name":"Never Gonna Give You Up""#, #""artists":[{"name":"Rick Astley"}]"#]
    if cover {
        parts.append(#""visualIdentity":{"image":[{"url":"\#(coverURL)","maxWidth":300}]}"#)
    }
    if preview {
        parts.append(#""audioPreview":{"url":"\#(previewURL)"}"#)
    }
    return "{" + parts.joined(separator: ",") + "}"
}

struct SpotifyMediaLoaderTests {
    @Test func downloadsTheCoverAndThePreviewClip() async throws {
        let cover = "https://image-cdn-fa.spotifycdn.com/image/ab67616d00001e02"
        let preview = "https://p.scdn.co/mp3-preview/40a780b2"
        StubProtocol.serve(cover, .init(headers: ["Content-Type": "image/jpeg"], body: Data("cover".utf8)))
        StubProtocol.serve(preview, .init(headers: ["Content-Type": "audio/mpeg"], body: Data("clip".utf8)))
        let recorder = FetchRecorder()

        let download = try #require(
            await loader(page(entity: entity()), recorder: recorder).download(for: trackURL))
        defer { try? FileManager.default.removeItem(at: download.files[0].deletingLastPathComponent()) }

        #expect(download.files.map(\.pathExtension) == ["jpg", "mp3"])
        #expect(try String(contentsOf: download.files[0], encoding: .utf8) == "cover")
        #expect(try String(contentsOf: download.files[1], encoding: .utf8) == "clip")
        #expect(download.caption == "Never Gonna Give You Up – Rick Astley")
        #expect(recorder.urls.map(\.absoluteString) == [
            "https://open.spotify.com/embed/track/4cOdK2wGLETKBW3PvgPWqT",
        ])
    }

    @Test func noPreviewSavesOnlyTheCover() async throws {
        let cover = "https://image-cdn-fa.spotifycdn.com/image/only"
        StubProtocol.serve(cover, .init(body: Data("cover".utf8)))

        let download = try #require(
            await loader(page(entity: entity(coverURL: cover, preview: false))).download(for: trackURL))
        defer { try? FileManager.default.removeItem(at: download.files[0].deletingLastPathComponent()) }

        #expect(download.files.map(\.pathExtension) == ["jpg"])
    }

    @Test func aPageFailureIsReported() async throws {
        let sink = ReportSink()

        #expect(await loader(nil, diagnostics: { sink.record($0) }).download(for: trackURL) == nil)

        let report = try #require(sink.reports.first)
        #expect(sink.reports.count == 1)
        #expect(report.contains("# Bug: Spotify media download failed"))
        #expect(report.contains(trackURL.absoluteString))
        #expect(report.contains("embed page"))
    }

    @Test func aPageWithoutMediaIsReported() async throws {
        let sink = ReportSink()

        #expect(await loader(page(entity: entity(cover: false, preview: false)),
                             diagnostics: { sink.record($0) }).download(for: trackURL) == nil)

        #expect(sink.reports.count == 1)
        #expect(sink.reports.first?.contains("no cover or preview") == true)
    }

    @Test func skipsAFileOverTheSizeLimit() async {
        let preview = "https://p.scdn.co/mp3-preview/big"
        StubProtocol.serve(preview, .init(headers: ["Content-Length": "5000"], body: Data(count: 5000)))
        var limits = SpotifyMediaLoader.Limits()
        limits.maxFileBytes = 1000

        #expect(await loader(page(entity: entity(cover: false, previewURL: preview)), limits: limits)
            .download(for: trackURL) == nil)
    }
}
