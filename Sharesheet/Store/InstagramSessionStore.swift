import Foundation
import InstagramMedia
import Security

/// The Instagram web session in the keychain. Never log the stored data.
struct InstagramSessionStore: Sendable {
    static let shared = InstagramSessionStore(
        service: "\(Bundle.main.bundleIdentifier ?? "Sharesheet").instagram-session")

    let service: String
    private let account = "instagram"

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
        guard let data = try? JSONEncoder().encode(session) else { return false }
        clear()
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
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
