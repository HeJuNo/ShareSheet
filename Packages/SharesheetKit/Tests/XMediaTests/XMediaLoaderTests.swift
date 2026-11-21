import Foundation
import Testing
import SharesheetCore
@testable import XMedia

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var _requests: [URLRequest] = []

    static var requests: [URLRequest] { lock.withLock { _requests } }

    static func serve(_ url: String, _ reply: Reply) {
        lock.withLock { replies[url] = reply }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self._requests.append(request) }
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

private struct StubFetcher: ResourceFetching {
    let body: String?

    func fetch(_ url: URL) async throws -> (data: Data, mimeType: String?) {
        guard let body else { throw URLError(.badServerResponse) }
        return (Data(body.utf8), "application/json")
    }
}

private final class ReportSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _reports: [String] = []

    var reports: [String] { lock.withLock { _reports } }
    func record(_ report: String) { lock.withLock { _reports.append(report) } }
}

private func loader(
    _ json: String?, limits: XMediaLoader.Limits = .init(),
    diagnostics: XMediaLoader.Diagnostics? = nil,
    session: WebSession? = nil
) -> XMediaLoader {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return XMediaLoader(
        fetcher: StubFetcher(body: json), limits: limits, configuration: configuration,
        diagnostics: diagnostics, session: { session })
}

private func signedInSession() -> WebSession {
    WebSession(cookies: [
        .init(name: "auth_token", value: "a", domain: ".x.com", path: "/"),
        .init(name: "ct0", value: "c", domain: ".x.com", path: "/"),
    ])
}

private let postURL = URL(string: "https://x.com/user/status/1234567890")!

struct XMediaLoaderTests {
    @Test func downloadsThePublicVideo() async throws {
        let video = "https://\(UUID().uuidString).test/720.mp4"
        StubProtocol.serve(video, .init(body: Data("v".utf8)))
        let json = #"""
        {"text":"Hello","mediaDetails":[{"type":"video","video_info":{"variants":[
         {"content_type":"video/mp4","bitrate":2176000,"url":"\#(video)"}
        ]}}]}
        """#

        let download = try #require(await loader(json).download(for: postURL))
        defer { try? FileManager.default.removeItem(at: download.files[0].deletingLastPathComponent()) }

        #expect(download.files.map(\.pathExtension) == ["mp4"])
        #expect(try String(contentsOf: download.files[0], encoding: .utf8) == "v")
        #expect(download.caption == "Hello")
    }

    @Test func noMediaAndNoSessionReports() async throws {
        let sink = ReportSink()

        #expect(await loader(#"{"text":"text only"}"#, diagnostics: { sink.record($0) })
            .download(for: postURL) == nil)

        let report = try #require(sink.reports.first)
        #expect(sink.reports.count == 1)
        #expect(report.contains("# Bug: X media download failed"))
        #expect(report.contains(postURL.absoluteString))
        #expect(report.contains("no images or videos"))
        #expect(!report.contains("sessionid"))
    }

    @Test func skipsAFileOverTheSizeLimit() async {
        let video = "https://\(UUID().uuidString).test/big.mp4"
        StubProtocol.serve(video, .init(headers: ["Content-Length": "5000"], body: Data(count: 5000)))
        let json = #"""
        {"mediaDetails":[{"type":"video","video_info":{"variants":[
         {"content_type":"video/mp4","bitrate":1,"url":"\#(video)"}
        ]}}]}
        """#
        var limits = XMediaLoader.Limits()
        limits.maxFileBytes = 1000

        #expect(await loader(json, limits: limits).download(for: postURL) == nil)
    }

    @Test func aSyndicationFailureIsReported() async throws {
        let sink = ReportSink()

        #expect(await loader(nil, diagnostics: { sink.record($0) }).download(for: postURL) == nil)

        #expect(sink.reports.count == 1)
        #expect(sink.reports.first?.contains("syndication") == true)
    }

    @Test func signedInPageIsUsedWhenSyndicationHasNoMedia() async throws {
        let signedInPost = URL(string: "https://x.com/user/status/1111111111")!
        let pageURL = "https://x.com/i/status/1111111111"
        let video = "https://video.twimg.com/amplify_video/111/vid/avc1/720x900/v.mp4"
        StubProtocol.serve(video, .init(body: Data("v".utf8)))
        let record = #"""
        {"data":{"tweet_result_by_rest_id":{"id":"x","rest_id":"1111111111","result":{
        "rest_id":"1111111111","media_entities2":[{"type":"video",
        "media_url_https":"https://pbs.twimg.com/amplify_video_thumb/111/img/p.jpg",
        "video_info":{"variants":[{"content_type":"video/mp4","bitrate":1,"url":"\#(video)"}]}}],
        "legacy":{"full_text":"Private post"}}}}}
        """#
        let escaped = String(decoding: try! JSONEncoder().encode(record), as: UTF8.self)
        StubProtocol.serve(pageURL, .init(
            headers: ["Content-Type": "text/html"],
            body: Data(#"<html><body><script>value:\#(escaped)</script></body></html>"#.utf8)))
        let sink = ReportSink()

        let download = try #require(
            await loader(#"{"text":""}"#, diagnostics: { sink.record($0) }, session: signedInSession())
                .download(for: signedInPost))
        defer { try? FileManager.default.removeItem(at: download.files[0].deletingLastPathComponent()) }

        #expect(download.files.count == 1)
        #expect(download.caption == "Private post")
        #expect(sink.reports.isEmpty)
        let page = try #require(StubProtocol.requests.first { $0.url?.absoluteString == pageURL })
        #expect(page.value(forHTTPHeaderField: "Cookie")?.contains("auth_token=a") == true)
        #expect(page.value(forHTTPHeaderField: "User-Agent")?.contains("Safari") == true)
    }

    @Test func anExpiredSignedInSessionIsReported() async throws {
        let expiredPost = URL(string: "https://x.com/user/status/2222222222")!
        let expiredPage = "https://x.com/i/status/2222222222"
        StubProtocol.serve(expiredPage, .init(status: 302, body: Data()))
        let sink = ReportSink()

        #expect(await loader(#"{"text":""}"#, diagnostics: { sink.record($0) }, session: signedInSession())
            .download(for: expiredPost) == nil)

        let report = try #require(sink.reports.first)
        #expect(sink.reports.count == 1)
        #expect(report.contains("session expired"))
    }

    @Test func noSessionDoesNotFetchThePage() async {
        let noSessionPost = URL(string: "https://x.com/user/status/3333333333")!
        let noSessionPage = "https://x.com/i/status/3333333333"
        let sink = ReportSink()

        #expect(await loader(#"{"text":""}"#, diagnostics: { sink.record($0) })
            .download(for: noSessionPost) == nil)
        #expect(!StubProtocol.requests.contains { $0.url?.absoluteString == noSessionPage })
        #expect(sink.reports.first?.contains("syndication") == true)
    }
}
