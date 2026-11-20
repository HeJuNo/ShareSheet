import Foundation

/// The cookies of a signed-in Instagram web session. Stored by the app in the keychain, never logged.
public struct InstagramSession: Codable, Equatable, Sendable {
    public struct Cookie: Codable, Equatable, Sendable {
        public var name: String
        public var value: String
        public var domain: String
        public var path: String
        public var expires: Date?
        public var secure: Bool

        public init(
            name: String, value: String, domain: String, path: String,
            expires: Date? = nil, secure: Bool = true
        ) {
            self.name = name
            self.value = value
            self.domain = domain
            self.path = path
            self.expires = expires
            self.secure = secure
        }
    }

    public var cookies: [Cookie]

    public init(cookies: [Cookie]) {
        self.cookies = cookies
    }

    /// False when the session ID is missing, empty, or expired.
    public var isUsable: Bool {
        guard let session = cookies.first(where: { $0.name == "sessionid" }), !session.value.isEmpty else {
            return false
        }
        if let expires = session.expires, expires <= Date() { return false }
        return true
    }

    /// `name=value` pairs for the request, without cookies that have expired.
    public var cookieHeader: String {
        cookies.filter { cookie in
            guard let expires = cookie.expires else { return true }
            return expires > Date()
        }.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    public var csrfToken: String? {
        cookies.first { $0.name == "csrftoken" }?.value
    }
}
