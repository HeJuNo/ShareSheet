import Foundation
import Testing
@testable import InstagramMedia

struct InstagramSessionTests {
    private func cookie(_ name: String, _ value: String, expires: Date? = nil) -> InstagramSession.Cookie {
        .init(name: name, value: value, domain: ".instagram.com", path: "/", expires: expires, secure: true)
    }

    @Test func roundTripsThroughJSON() throws {
        let session = InstagramSession(cookies: [cookie("sessionid", "abc"), cookie("csrftoken", "xyz")])
        let data = try JSONEncoder().encode(session)
        #expect(try JSONDecoder().decode(InstagramSession.self, from: data) == session)
    }

    @Test func cookieHeaderSkipsExpiredCookies() {
        let session = InstagramSession(cookies: [
            cookie("sessionid", "abc"),
            cookie("old", "gone", expires: .now.addingTimeInterval(-60)),
            cookie("csrftoken", "xyz"),
        ])
        #expect(session.cookieHeader == "sessionid=abc; csrftoken=xyz")
    }

    @Test func isUsableNeedsALiveSessionID() {
        #expect(!InstagramSession(cookies: [cookie("csrftoken", "x")]).isUsable)
        #expect(!InstagramSession(cookies: [cookie("sessionid", "")]).isUsable)
        #expect(!InstagramSession(cookies: [cookie("sessionid", "x", expires: .now.addingTimeInterval(-1))]).isUsable)
        #expect(InstagramSession(cookies: [cookie("sessionid", "x")]).isUsable)
    }

    @Test func readsTheCSRFToken() {
        #expect(InstagramSession(cookies: [cookie("csrftoken", "xyz")]).csrfToken == "xyz")
        #expect(InstagramSession(cookies: []).csrfToken == nil)
    }

    @Test func convertsAShortcodeToTheMediaID() {
        #expect(InstagramMediaID.string(for: "DfNDnB4oZut") == "4020885918534704045")
    }

    @Test func rejectsInvalidShortcodes() {
        #expect(InstagramMediaID.string(for: "") == nil)
        #expect(InstagramMediaID.string(for: "abc!") == nil)
        #expect(InstagramMediaID.string(for: String(repeating: "z", count: 12)) == nil)
    }
}
