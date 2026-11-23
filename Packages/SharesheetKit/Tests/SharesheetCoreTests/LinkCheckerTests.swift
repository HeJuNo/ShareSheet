import Foundation
import Testing
@testable import SharesheetCore

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var error: URLError?
        var body = Data()
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var _requests: [URLRequest] = []

    static var requests: [URLRequest] { lock.withLock { _requests } }

    static func serve(_ url: URL, _ reply: Reply) {
        lock.withLock { replies[url.absoluteString] = reply }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self._requests.append(request) }
        guard let url = request.url, let reply = Self.lock.withLock({ Self.replies[url.absoluteString] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func checker() -> LinkChecker {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return LinkChecker(configuration: configuration)
}

private func uniqueURL() -> URL {
    URL(string: "https://\(UUID().uuidString).test/")!
}

@Suite struct LinkCheckerTests {
    @Test func aSuccessfulPageIsOK() async {
        let url = uniqueURL()
        StubProtocol.serve(url, .init(body: Data("ok".utf8)))
        #expect(await checker().check(url) == LinkCheckResult(status: .ok, httpStatus: 200))
    }

    @Test func notFoundAndGoneAreBroken() async {
        for status in [404, 410] {
            let url = uniqueURL()
            StubProtocol.serve(url, .init(status: status))
            #expect(await checker().check(url) == LinkCheckResult(status: .broken, httpStatus: status))
        }
    }

    @Test func serverErrorsAndTimeoutsAreUnknown() async {
        let serverError = uniqueURL()
        StubProtocol.serve(serverError, .init(status: 500))
        #expect(await checker().check(serverError) == LinkCheckResult(status: .unknown, httpStatus: 500))

        let timeout = uniqueURL()
        StubProtocol.serve(timeout, .init(error: URLError(.timedOut)))
        #expect(await checker().check(timeout) == LinkCheckResult(status: .unknown))
    }

    @Test func hostFailuresAreBroken() async {
        for code in [URLError.Code.cannotFindHost, .dnsLookupFailed, .cannotConnectToHost] {
            let url = uniqueURL()
            StubProtocol.serve(url, .init(error: URLError(code)))
            #expect(await checker().check(url) == LinkCheckResult(status: .broken))
        }
    }

    @Test func offlineIsUnknown() async {
        let url = uniqueURL()
        StubProtocol.serve(url, .init(error: URLError(.notConnectedToInternet)))
        #expect(await checker().check(url) == LinkCheckResult(status: .unknown))
    }

    @Test func theCheckSendsNoCookies() async throws {
        let url = uniqueURL()
        StubProtocol.serve(url, .init(body: Data("ok".utf8)))
        _ = await checker().check(url)
        let request = try #require(StubProtocol.requests.last { $0.url == url })
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
    }
}
