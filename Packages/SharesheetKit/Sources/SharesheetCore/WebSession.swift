import Foundation

/// The result of checking a stored web session against its service.
public enum SessionStatus: Sendable, Equatable {
    case noSession
    case valid
    case expired
    case unknown
}

/// Cookies of a signed-in web session, shared by Instagram and X. The app stores it in the keychain.
public struct WebSession: Codable, Equatable, Sendable {
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

    /// False when the session's required cookie is missing, empty, or expired.
    public func isUsable(requiredCookie: String) -> Bool {
        guard let cookie = cookies.first(where: { $0.name == requiredCookie }), !cookie.value.isEmpty else {
            return false
        }
        if let expires = cookie.expires, expires <= Date() { return false }
        return true
    }

    public func value(named name: String) -> String? {
        cookies.first { $0.name == name }?.value
    }

    /// `name=value` pairs for the request, without cookies that have expired.
    public var cookieHeader: String {
        cookies.filter { cookie in
            guard let expires = cookie.expires else { return true }
            return expires > Date()
        }.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}
