import Foundation

public enum LinkStatus: String, Sendable, Equatable {
    case ok, broken, unknown
}

public struct LinkCheckResult: Equatable, Sendable {
    public var status: LinkStatus
    public var httpStatus: Int?

    public init(status: LinkStatus, httpStatus: Int? = nil) {
        self.status = status
        self.httpStatus = httpStatus
    }
}

public struct StoredLinkCheck: Equatable, Sendable {
    public var status: LinkStatus
    public var httpStatus: Int?
    public var checked: Date
}

public struct BrokenLink: Identifiable, Equatable, Sendable {
    public var item: IndexedItem
    public var check: StoredLinkCheck
    public var id: ItemID { item.id }
}

/// Checks whether a public link answers. No cookies, no session, no body read.
public struct LinkChecker: Sendable {
    private static let safariUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    private let session: URLSession

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        self.session = URLSession(configuration: configuration)
    }

    public func check(_ url: URL) async -> LinkCheckResult {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(Self.safariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        do {
            let (bytes, response) = try await session.bytes(for: request)
            bytes.task.cancel()
            guard let http = response as? HTTPURLResponse else {
                return LinkCheckResult(status: .unknown)
            }
            switch http.statusCode {
            case 200..<400:
                return LinkCheckResult(status: .ok, httpStatus: http.statusCode)
            case 404, 410:
                return LinkCheckResult(status: .broken, httpStatus: http.statusCode)
            default:
                return LinkCheckResult(status: .unknown, httpStatus: http.statusCode)
            }
        } catch let error as URLError {
            switch error.code {
            case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost:
                return LinkCheckResult(status: .broken)
            default:
                return LinkCheckResult(status: .unknown)
            }
        } catch {
            return LinkCheckResult(status: .unknown)
        }
    }
}
