import Foundation
import InstagramMedia
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
    /// (`errSecMissingEntitlement`). A signed run or the device exercises these tests.
    private func makeStore() -> InstagramSessionStore? {
        let store = InstagramSessionStore(service: "test-\(UUID().uuidString)")
        guard store.save(session()) else { return nil }
        store.clear()
        return store
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
        #expect(store.load()?.isUsable == false)
    }
}
