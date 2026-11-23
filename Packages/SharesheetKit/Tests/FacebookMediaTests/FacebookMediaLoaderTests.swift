import Foundation
import Testing
import SharesheetCore
@testable import FacebookMedia

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var anonymous: [String: Reply] = [:]
    nonisolated(unsafe) private static var signedIn: [String: Reply] = [:]
    nonisolated(unsafe) private static var recorded: [URLRequest] = []

    static var requests: [URLRequest] { lock.withLock { recorded } }

    static func serve(_ url: String, _ reply: Reply, signedIn: Bool = false) {
        lock.withLock {
            if signedIn { Self.signedIn[url] = reply } else { Self.anonymous[url] = reply }
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let hasCookie = request.value(forHTTPHeaderField: "Cookie") != nil
        let reply = Self.lock.withLock { () -> Reply? in
            Self.recorded.append(request)
            guard let url = request.url?.absoluteString else { return nil }
            return hasCookie ? (Self.signedIn[url] ?? Self.anonymous[url]) : Self.anonymous[url]
        }
        guard let url = request.url, let reply else {
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

private final class ReportSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _reports: [String] = []

    var reports: [String] { lock.withLock { _reports } }
    func record(_ report: String) { lock.withLock { _reports.append(report) } }
}

private func loader(
    limits: FacebookMediaLoader.Limits = .init(),
    diagnostics: FacebookMediaLoader.Diagnostics? = nil,
    session: WebSession? = nil
) -> FacebookMediaLoader {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return FacebookMediaLoader(
        limits: limits, configuration: configuration, diagnostics: diagnostics, session: { session })
}

private func signedInSession() -> WebSession {
    WebSession(cookies: [
        .init(name: "c_user", value: "1", domain: ".facebook.com", path: "/"),
        .init(name: "xs", value: "x", domain: ".facebook.com", path: "/"),
    ])
}

private func page(video: String? = nil, photo: String? = nil, signedIn: Bool = false) -> String {
    var head = #"<meta property="og:description" content="A post">"#
    if let photo {
        head += #"<meta property="og:image" content="\#(photo)">"#
    }
    var script = ""
    if let video {
        script = #"<script>{"browser_native_hd_url":"\#(video.replacingOccurrences(of: "/", with: "\\/"))"}</script>"#
    }
    _ = signedIn
    return "<html><head>\(head)</head><body>\(script)</body></html>"
}

struct FacebookMediaLoaderTests {
    @Test func downloadsThePublicVideo() async throws {
        let post = URL(string: "https://www.facebook.com/user/posts/1111111111")!
        let video = "https://video.xx.fbcdn.net/v/\(UUID().uuidString)/hd.mp4"
        StubProtocol.serve(post.absoluteString, .init(body: Data(page(video: video).utf8)))
        StubProtocol.serve(video, .init(body: Data("video".utf8)))

        let download = try #require(await loader().download(for: post))
        defer { try? FileManager.default.removeItem(at: download.files[0].deletingLastPathComponent()) }

        #expect(download.files.map(\.pathExtension) == ["mp4"])
        #expect(try String(contentsOf: download.files[0], encoding: .utf8) == "video")
        #expect(download.caption == "A post")
    }

    @Test func signedInPageIsUsedWhenThePublicPageHasNoMedia() async throws {
        let post = URL(string: "https://www.facebook.com/user/posts/2222222222")!
        let photo = "https://scontent.xx.fbcdn.net/v/\(UUID().uuidString)/photo.jpg"
        StubProtocol.serve(post.absoluteString, .init(body: Data("<html><body>Log into Facebook</body></html>".utf8)))
        StubProtocol.serve(post.absoluteString, .init(body: Data(page(photo: photo).utf8)), signedIn: true)
        StubProtocol.serve(photo, .init(body: Data("photo".utf8)))

        let download = try #require(await loader(session: signedInSession()).download(for: post))
        defer { try? FileManager.default.removeItem(at: download.files[0].deletingLastPathComponent()) }

        #expect(download.files.map(\.pathExtension) == ["jpg"])
        let signed = try #require(StubProtocol.requests.first {
            $0.url == post && $0.value(forHTTPHeaderField: "Cookie")?.contains("c_user=1") == true
        })
        #expect(signed.value(forHTTPHeaderField: "User-Agent")?.contains("Safari") == true)
    }

    @Test func anExpiredSessionIsReported() async throws {
        let post = URL(string: "https://www.facebook.com/user/posts/3333333333")!
        StubProtocol.serve(post.absoluteString, .init(body: Data("<html><body>nothing</body></html>".utf8)))
        StubProtocol.serve(
            post.absoluteString,
            .init(body: Data(#"<html><body><div id="login_form"></div></body></html>"#.utf8)),
            signedIn: true)
        let sink = ReportSink()

        #expect(await loader(diagnostics: { sink.record($0) }, session: signedInSession())
            .download(for: post) == nil)

        let report = try #require(sink.reports.first)
        #expect(sink.reports.count == 1)
        #expect(report.contains("session expired"))
    }

    @Test func noMediaAndNoSessionReports() async throws {
        let post = URL(string: "https://www.facebook.com/user/posts/4444444444")!
        StubProtocol.serve(post.absoluteString, .init(body: Data("<html><body>nothing</body></html>".utf8)))
        let sink = ReportSink()

        #expect(await loader(diagnostics: { sink.record($0) }).download(for: post) == nil)

        let report = try #require(sink.reports.first)
        #expect(sink.reports.count == 1)
        #expect(report.contains("# Bug: Facebook media download failed"))
        #expect(report.contains(post.absoluteString))
        #expect(report.contains("no images or videos"))
    }

    @Test func aNonFacebookLinkIsIgnored() async {
        #expect(await loader().download(for: URL(string: "https://example.com/post")!) == nil)
    }

    @Test func skipsAFileOverTheSizeLimit() async {
        let post = URL(string: "https://www.facebook.com/user/posts/5555555555")!
        let video = "https://video.xx.fbcdn.net/v/\(UUID().uuidString)/big.mp4"
        StubProtocol.serve(post.absoluteString, .init(body: Data(page(video: video).utf8)))
        StubProtocol.serve(video, .init(headers: ["Content-Length": "5000"], body: Data(count: 5000)))
        var limits = FacebookMediaLoader.Limits()
        limits.maxFileBytes = 1000

        #expect(await loader(limits: limits).download(for: post) == nil)
    }

    @Test func validateSessionReportsAValidSession() async {
        let url = uniqueProbeURL()
        StubProtocol.serve(url.absoluteString, .init(
            body: Data("<html><head><title>Facebook</title></head></html>".utf8)))
        #expect(await loader(session: signedInSession()).validateSession(probeURL: url) == .valid)
    }

    @Test func validateSessionReportsAnExpiredSessionOnTheLoginPage() async {
        let url = uniqueProbeURL()
        StubProtocol.serve(url.absoluteString, .init(
            body: Data("<html><head><title>Log in</title></head></html>".utf8)))
        #expect(await loader(session: signedInSession()).validateSession(probeURL: url) == .expired)
    }

    @Test func validateSessionReportsAnExpiredSessionOnAnUnauthorizedStatus() async {
        let url = uniqueProbeURL()
        StubProtocol.serve(url.absoluteString, .init(status: 401, body: Data()))
        #expect(await loader(session: signedInSession()).validateSession(probeURL: url) == .expired)
    }

    @Test func validateSessionReportsUnknownOnAServerError() async {
        let url = uniqueProbeURL()
        StubProtocol.serve(url.absoluteString, .init(status: 500, body: Data()))
        #expect(await loader(session: signedInSession()).validateSession(probeURL: url) == .unknown)
    }

    @Test func validateSessionReportsUnknownOnANonUTF8ServerError() async {
        let url = uniqueProbeURL()
        StubProtocol.serve(url.absoluteString, .init(status: 500, body: Data([0xFF, 0xFE])))
        #expect(await loader(session: signedInSession()).validateSession(probeURL: url) == .unknown)
    }

    @Test func validateSessionReportsUnknownWhenTheRequestFails() async {
        #expect(await loader(session: signedInSession())
            .validateSession(probeURL: uniqueProbeURL()) == .unknown)
    }

    @Test func validateSessionWithoutAStoredSessionIsNoSession() async {
        let url = uniqueProbeURL()
        #expect(await loader().validateSession(probeURL: url) == .noSession)
        #expect(!StubProtocol.requests.contains { $0.url == url })
    }

    @Test func validateSessionReportsAnExpiredSessionForALocallyExpiredCookie() async {
        let url = uniqueProbeURL()
        let expired = WebSession(cookies: [
            .init(name: "c_user", value: "1", domain: ".facebook.com", path: "/",
                  expires: Date(timeIntervalSince1970: 0))
        ])
        #expect(await loader(session: expired).validateSession(probeURL: url) == .expired)
        #expect(!StubProtocol.requests.contains { $0.url == url })
    }
}

private func uniqueProbeURL() -> URL {
    URL(string: "https://\(UUID().uuidString).test/probe")!
}
