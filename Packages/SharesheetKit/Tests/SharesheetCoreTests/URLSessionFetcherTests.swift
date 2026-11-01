import Foundation
import Testing
@testable import SharesheetCore

/// Serves canned responses by host, so tests running in parallel don't share state.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var headers: [String: String] = [:]
        var body: Data
        /// When false the body is sent but the load never finishes, like a server that keeps streaming.
        var finishes = true
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]

    static func serve(_ reply: Reply) -> URL {
        let host = "stub-\(UUID().uuidString.lowercased()).test"
        lock.withLock { replies[host] = reply }
        return URL(string: "https://\(host)/resource")!
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let reply = Self.lock.withLock({ Self.replies[url.host() ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        if reply.finishes { client?.urlProtocolDidFinishLoading(self) }
    }

    override func stopLoading() {}
}

private func fetcher(maxBytes: Int, timeout: TimeInterval = 5) -> URLSessionFetcher {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return URLSessionFetcher(configuration: configuration, timeout: timeout, maxBytes: maxBytes)
}

@Test func fetcherReturnsASmallBody() async throws {
    let url = StubProtocol.serve(.init(headers: ["Content-Type": "text/css"], body: Data("a{}".utf8)))
    let result = try await fetcher(maxBytes: 100).fetch(url)
    #expect(result.data == Data("a{}".utf8) && result.mimeType == "text/css")
}

@Test func fetcherRejectsADeclaredLengthOverTheLimit() async throws {
    let url = StubProtocol.serve(.init(headers: ["Content-Length": "5000"], body: Data(count: 5000)))
    await #expect(throws: URLSessionFetcher.TooLarge.self) { _ = try await fetcher(maxBytes: 1000).fetch(url) }
}

@Test func fetcherStopsReadingAnEndlessBodyAtTheLimit() async throws {
    // No length and no end: buffering the whole body would wait for the timeout instead.
    let url = StubProtocol.serve(.init(body: Data(count: 4096), finishes: false))
    let start = Date()
    await #expect(throws: URLSessionFetcher.TooLarge.self) {
        _ = try await fetcher(maxBytes: 1000, timeout: 3).fetch(url)
    }
    #expect(Date().timeIntervalSince(start) < 2)
}
