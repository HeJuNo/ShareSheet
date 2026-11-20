import Foundation
import Testing
@testable import InstagramMedia
import SharesheetCore

/// Serves canned responses by full URL; unique hosts keep parallel tests apart.
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

private struct StubEmbed: ResourceFetching {
    let html: String
    func fetch(_ url: URL) async throws -> (data: Data, mimeType: String?) {
        (Data(html.utf8), "text/html")
    }
}

private struct FailingEmbed: ResourceFetching {
    func fetch(_ url: URL) async throws -> (data: Data, mimeType: String?) {
        throw URLError(.badServerResponse)
    }
}

private final class RecordingEmbed: ResourceFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _asked = 0
    var asked: Int { lock.withLock { _asked } }

    func fetch(_ url: URL) async throws -> (data: Data, mimeType: String?) {
        lock.withLock { _asked += 1 }
        return (Data(), nil)
    }
}

private final class ReportSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _reports: [String] = []

    var reports: [String] { lock.withLock { _reports } }
    func record(_ report: String) { lock.withLock { _reports.append(report) } }
}

private func loader(
    _ html: String, limits: InstagramMediaLoader.Limits = .init(),
    diagnostics: InstagramMediaLoader.Diagnostics? = nil,
    session: InstagramSession? = nil
) -> InstagramMediaLoader {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return InstagramMediaLoader(
        fetcher: StubEmbed(html: html), limits: limits, configuration: configuration,
        diagnostics: diagnostics, session: { session })
}

private func signedInSession() -> InstagramSession {
    InstagramSession(cookies: [
        .init(name: "sessionid", value: "s3", domain: ".instagram.com", path: "/"),
        .init(name: "csrftoken", value: "csrf", domain: ".instagram.com", path: "/"),
    ])
}

private func apiJSON(_ image: String) -> String {
    #"{"status":"ok","items":[{"image_versions2":{"candidates":[{"url":"\#(image)","width":1080}]},"caption":{"text":"Private post"}}]}"#
}

/// Sidecar-HTML mit den gegebenen Medien; `.mp4` wird zum Video, alles andere zum Bild.
private func mediaHTML(_ urls: [String], caption: String? = "A caption") -> String {
    let nodes = urls.map { url in
        url.hasSuffix(".mp4")
            ? #"{"node":{"display_url":"https://media.test/thumb.jpg","video_url":"\#(url)"}}"#
            : #"{"node":{"display_url":"\#(url)"}}"#
    }.joined(separator: ",")
    let captionPart = caption.map {
        #","edge_media_to_caption":{"edges":[{"node":{"text":"\#($0)"}}]}"#
    } ?? ""
    return #"{"gql_data":{"shortcode_media":{"edge_sidecar_to_children":{"edges":[\#(nodes)]}\#(captionPart)}}}"#
}

private let postURL = URL(string: "https://www.instagram.com/p/C1a2b3c/")!

struct InstagramMediaLoaderTests {
    @Test func downloadsEachMediaFileInOrder() async throws {
        let image = "https://\(UUID().uuidString).test/1.jpg"
        let video = "https://\(UUID().uuidString).test/2.mp4"
        StubProtocol.serve(image, .init(body: Data("j".utf8)))
        StubProtocol.serve(video, .init(body: Data("v".utf8)))

        let download = try #require(
            await loader(embedHTML(mediaHTML([image, video]))).download(for: postURL))
        defer { try? FileManager.default.removeItem(at: download.files[0].deletingLastPathComponent()) }

        #expect(download.files.map(\.pathExtension) == ["jpg", "mp4"])
        #expect(try String(contentsOf: download.files[0], encoding: .utf8) == "j")
        #expect(try String(contentsOf: download.files[1], encoding: .utf8) == "v")
        #expect(download.caption == "A caption")
    }

    @Test func stopsAtTheItemLimit() async throws {
        let urls = (1...3).map { "https://\(UUID().uuidString).test/\($0).jpg" }
        for url in urls { StubProtocol.serve(url, .init(body: Data("x".utf8))) }
        var limits = InstagramMediaLoader.Limits()
        limits.maxItems = 2

        let download = try #require(
            await loader(embedHTML(mediaHTML(urls)), limits: limits).download(for: postURL))
        defer { try? FileManager.default.removeItem(at: download.files[0].deletingLastPathComponent()) }

        #expect(download.files.count == 2)
    }

    @Test func skipsAFileOverTheSizeLimit() async {
        let url = "https://\(UUID().uuidString).test/big.jpg"
        StubProtocol.serve(url, .init(headers: ["Content-Length": "5000"], body: Data(count: 5000)))
        var limits = InstagramMediaLoader.Limits()
        limits.maxFileBytes = 1000

        #expect(await loader(embedHTML(mediaHTML([url])), limits: limits).download(for: postURL) == nil)
    }

    @Test func skipsAFileOverTheTotalLimit() async throws {
        let first = "https://\(UUID().uuidString).test/1.jpg"
        let second = "https://\(UUID().uuidString).test/2.jpg"
        for url in [first, second] {
            StubProtocol.serve(url, .init(headers: ["Content-Length": "60"], body: Data(count: 60)))
        }
        var limits = InstagramMediaLoader.Limits()
        limits.totalBytes = 100

        let download = try #require(
            await loader(embedHTML(mediaHTML([first, second])), limits: limits).download(for: postURL))
        defer { try? FileManager.default.removeItem(at: download.files[0].deletingLastPathComponent()) }

        #expect(download.files.count == 1)
    }

    @Test func keepsTheOthersWhenOneFails() async throws {
        let good = "https://\(UUID().uuidString).test/1.jpg"
        let bad = "https://\(UUID().uuidString).test/2.jpg"
        StubProtocol.serve(good, .init(body: Data("ok".utf8)))
        StubProtocol.serve(bad, .init(status: 404, body: Data()))

        let download = try #require(
            await loader(embedHTML(mediaHTML([bad, good]))).download(for: postURL))
        defer { try? FileManager.default.removeItem(at: download.files[0].deletingLastPathComponent()) }

        #expect(download.files.count == 1)
        #expect(try String(contentsOf: download.files[0], encoding: .utf8) == "ok")
    }

    @Test func returnsNilWhenTheEmbedCannotBeRead() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let loader = InstagramMediaLoader(fetcher: FailingEmbed(), limits: .init(), configuration: configuration)
        #expect(await loader.download(for: postURL) == nil)
    }

    @Test func ignoresNonInstagramLinks() async {
        let embed = RecordingEmbed()
        let loader = InstagramMediaLoader(fetcher: embed)
        #expect(await loader.download(for: URL(string: "https://example.com/p/C1a2b3c/")!) == nil)
        #expect(embed.asked == 0)
    }

    // MARK: Diagnostics

    @Test func reportsAFailedEmbedFetch() async throws {
        let sink = ReportSink()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let loader = InstagramMediaLoader(
            fetcher: FailingEmbed(), limits: .init(), configuration: configuration,
            diagnostics: { sink.record($0) })

        #expect(await loader.download(for: postURL) == nil)
        let report = try #require(sink.reports.first)
        #expect(report.contains("# Bug: Instagram media download failed"))
        #expect(report.contains(postURL.absoluteString))
        #expect(report.contains("fetch embed page"))
    }

    @Test func reportsADecodeFailure() async throws {
        let sink = ReportSink()

        #expect(await loader("<html></html>", diagnostics: { sink.record($0) }).download(for: postURL) == nil)
        let report = try #require(sink.reports.first)
        #expect(report.contains("decode contextJSON"))
    }

    @Test func reportsTheMediaThatFailedWhileOthersSucceeded() async throws {
        let good = "https://\(UUID().uuidString).test/1.jpg"
        let bad = "https://\(UUID().uuidString).test/2.jpg"
        StubProtocol.serve(good, .init(body: Data("ok".utf8)))
        StubProtocol.serve(bad, .init(status: 404, body: Data()))
        let sink = ReportSink()

        let download = try #require(
            await loader(embedHTML(mediaHTML([bad, good])), diagnostics: { sink.record($0) })
                .download(for: postURL))
        defer { try? FileManager.default.removeItem(at: download.files[0].deletingLastPathComponent()) }

        #expect(download.files.count == 1)
        let report = try #require(sink.reports.first)
        #expect(report.contains("1 of 2 failed"))
        #expect(report.contains(bad))
        #expect(report.contains("HTTP 404"))
    }

    @Test func successWritesNoReport() async throws {
        let url = "https://\(UUID().uuidString).test/1.jpg"
        StubProtocol.serve(url, .init(body: Data("x".utf8)))
        let sink = ReportSink()

        let download = try #require(
            await loader(embedHTML(mediaHTML([url])), diagnostics: { sink.record($0) }).download(for: postURL))
        defer { try? FileManager.default.removeItem(at: download.files[0].deletingLastPathComponent()) }

        #expect(sink.reports.isEmpty)
    }

    // MARK: Signed-in fallback

    @Test func anonymousSuccessDoesNotCallTheAPI() async throws {
        let image = "https://\(UUID().uuidString).test/1.jpg"
        StubProtocol.serve(image, .init(body: Data("x".utf8)))
        let code = "AbCdEf1"
        let apiURL = "https://www.instagram.com/api/v1/media/\(InstagramMediaID.string(for: code)!)/info/"

        let download = try #require(
            await loader(embedHTML(mediaHTML([image])), session: signedInSession())
                .download(for: URL(string: "https://www.instagram.com/p/\(code)/")!))
        defer { try? FileManager.default.removeItem(at: download.files[0].deletingLastPathComponent()) }

        #expect(download.files.count == 1)
        #expect(!StubProtocol.requests.contains { $0.url?.absoluteString == apiURL })
    }

    @Test func signedInMediaIsUsedWhenTheEmbedHasNone() async throws {
        let image = "https://\(UUID().uuidString).test/1.jpg"
        let code = "Signed1"
        let apiURL = "https://www.instagram.com/api/v1/media/\(InstagramMediaID.string(for: code)!)/info/"
        StubProtocol.serve(image, .init(body: Data("x".utf8)))
        StubProtocol.serve(apiURL, .init(
            headers: ["Content-Type": "application/json"], body: Data(apiJSON(image).utf8)))
        let sink = ReportSink()

        let download = try #require(
            await loader("<html></html>", diagnostics: { sink.record($0) }, session: signedInSession())
                .download(for: URL(string: "https://www.instagram.com/p/\(code)/")!))
        defer { try? FileManager.default.removeItem(at: download.files[0].deletingLastPathComponent()) }

        #expect(download.files.count == 1)
        #expect(download.caption == "Private post")
        #expect(sink.reports.isEmpty)
        let request = try #require(StubProtocol.requests.first { $0.url?.absoluteString == apiURL })
        #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("sessionid=s3") == true)
        #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("csrftoken=csrf") == true)
        #expect(request.value(forHTTPHeaderField: "X-CSRFToken") == "csrf")
        #expect(request.value(forHTTPHeaderField: "X-IG-App-ID") == "936619743392459")
        #expect(request.value(forHTTPHeaderField: "X-Requested-With") == "XMLHttpRequest")
    }

    @Test func expiredSessionIsReported() async throws {
        let code = "Expired1"
        let apiURL = "https://www.instagram.com/api/v1/media/\(InstagramMediaID.string(for: code)!)/info/"
        StubProtocol.serve(apiURL, .init(
            status: 302, headers: ["Location": "https://www.instagram.com/accounts/login/"], body: Data()))
        StubProtocol.serve("https://www.instagram.com/accounts/login/", .init(body: Data("<html>login</html>".utf8)))
        let sink = ReportSink()

        #expect(await loader("<html></html>", diagnostics: { sink.record($0) }, session: signedInSession())
            .download(for: URL(string: "https://www.instagram.com/p/\(code)/")!) == nil)
        let report = try #require(sink.reports.first)
        #expect(sink.reports.count == 1)
        #expect(report.contains("signed-in media API"))
        #expect(report.contains("session expired"))
    }

    @Test func noSessionDoesNotCallTheAPI() async {
        let code = "NoSess1"
        let apiURL = "https://www.instagram.com/api/v1/media/\(InstagramMediaID.string(for: code)!)/info/"
        let sink = ReportSink()

        #expect(await loader("<html></html>", diagnostics: { sink.record($0) })
            .download(for: URL(string: "https://www.instagram.com/p/\(code)/")!) == nil)
        #expect(!StubProtocol.requests.contains { $0.url?.absoluteString == apiURL })
        #expect(sink.reports.first?.contains("decode contextJSON") == true)
    }

    @Test func anExpiredStoredSessionIsMentioned() async throws {
        let expired = InstagramSession(cookies: [
            .init(name: "sessionid", value: "old", domain: ".instagram.com", path: "/",
                  expires: .now.addingTimeInterval(-60)),
        ])
        let sink = ReportSink()

        #expect(await loader("<html></html>", diagnostics: { sink.record($0) }, session: expired)
            .download(for: URL(string: "https://www.instagram.com/p/Expired0/")!) == nil)
        let report = try #require(sink.reports.first)
        #expect(report.contains("decode contextJSON"))
        #expect(report.contains("session has expired"))
    }
}
