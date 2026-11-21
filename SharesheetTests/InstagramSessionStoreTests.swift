import Foundation
import InstagramMedia
import Security
import Testing
@testable import Sharesheet

struct InstagramSessionStoreTests {
    private func session() -> InstagramSession {
        InstagramSession(cookies: [
            .init(name: "sessionid", value: "abc", domain: ".instagram.com", path: "/"),
            .init(name: "csrftoken", value: "xyz", domain: ".instagram.com", path: "/"),
        ])
    }

    /// `work/build.sh sim-test` builds the host unsigned, which cannot access the keychain
    /// (`errSecMissingEntitlement`); any other failure fails the test instead of skipping it.
    private func makeStore() -> InstagramSessionStore? {
        let store = InstagramSessionStore(service: "test-\(UUID().uuidString)")
        let status = store.saveStatus(session())
        store.clear()
        if status == errSecMissingEntitlement { return nil }
        #expect(status == errSecSuccess, "Keychain save failed with status \(status)")
        return status == errSecSuccess ? store : nil
    }

    @Test func roundTripsAndClears() {
        guard let store = makeStore() else { return }
        defer { store.clear() }

        #expect(store.load() == nil)
        #expect(store.save(session()))
        #expect(store.load() == session())
        store.clear()
        #expect(store.load() == nil)
    }

    @Test func savesAnExpiredSessionButItIsNotUsable() {
        guard let store = makeStore() else { return }
        defer { store.clear() }
        let expired = InstagramSession(cookies: [
            .init(name: "sessionid", value: "old", domain: ".instagram.com", path: "/",
                  expires: .now.addingTimeInterval(-60)),
        ])

        #expect(store.save(expired))
        #expect(store.load()?.isUsable(requiredCookie: "sessionid") == false)
    }

    @Test @MainActor func loginUsesANonPersistentWebStore() {
        #expect(!InstagramLoginModel.makeConfiguration().websiteDataStore.isPersistent)
    }

    @Test func roundTripsTheXService() {
        let store = WebSessionStore(service: "test-x-\(UUID().uuidString)", account: "x")
        defer { store.clear() }
        let session = InstagramSession(cookies: [
            .init(name: "auth_token", value: "a", domain: ".x.com", path: "/"),
        ])
        let status = store.saveStatus(session)
        if status == errSecMissingEntitlement { return }
        #expect(status == errSecSuccess, "Keychain save failed with status \(status)")
        guard status == errSecSuccess else { return }

        #expect(store.load() == session)
        store.clear()
        #expect(store.load() == nil)
    }
}
