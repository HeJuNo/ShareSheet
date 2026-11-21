import Foundation
import InstagramMedia
import Security

/// A web session in the keychain. Never log the stored data.
struct WebSessionStore: Sendable {
    static let shared = WebSessionStore(
        service: "\(Bundle.main.bundleIdentifier ?? "Sharesheet").instagram-session")

    let service: String
    private let account: String

    init(service: String, account: String = "instagram") {
        self.service = service
        self.account = account
    }

    func load() -> InstagramSession? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return try? JSONDecoder().decode(InstagramSession.self, from: data)
    }

    @discardableResult
    func save(_ session: InstagramSession) -> Bool {
        saveStatus(session) == errSecSuccess
    }

    /// The raw status lets tests distinguish an unsigned test host from a real failure.
    func saveStatus(_ session: InstagramSession) -> OSStatus {
        guard let data = try? JSONEncoder().encode(session) else { return errSecParam }
        clear()
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Instagram keeps its session in the shared store under the Instagram service.
typealias InstagramSessionStore = WebSessionStore

extension WebSessionStore {
    /// X's own keychain entry; the cookie names and domains differ from Instagram.
    static let x = WebSessionStore(
        service: "\(Bundle.main.bundleIdentifier ?? "Sharesheet").x-session",
        account: "x")

    /// Facebook's own keychain entry; `c_user` marks a signed-in session.
    static let facebook = WebSessionStore(
        service: "\(Bundle.main.bundleIdentifier ?? "Sharesheet").facebook-session",
        account: "facebook")
}
