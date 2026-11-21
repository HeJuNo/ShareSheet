import Foundation
import Testing
@testable import SharesheetCore

struct WebSessionTests {
    private func cookie(_ name: String, _ value: String, expires: Date? = nil) -> WebSession.Cookie {
        .init(name: name, value: value, domain: ".instagram.com", path: "/", expires: expires, secure: true)
    }

    @Test func roundTripsThroughJSON() throws {
        let session = WebSession(cookies: [cookie("sessionid", "abc"), cookie("csrftoken", "xyz")])
        let data = try JSONEncoder().encode(session)
        #expect(try JSONDecoder().decode(WebSession.self, from: data) == session)
    }

    @Test func headerSkipsExpiredCookies() {
        let session = WebSession(cookies: [
            cookie("sessionid", "abc"),
            cookie("old", "gone", expires: .now.addingTimeInterval(-60)),
            cookie("csrftoken", "xyz"),
        ])
        #expect(session.cookieHeader == "sessionid=abc; csrftoken=xyz")
    }

    @Test func usabilityNeedsTheRequiredCookie() {
        let session = WebSession(cookies: [cookie("sessionid", "abc")])
        #expect(session.isUsable(requiredCookie: "sessionid"))
        #expect(!session.isUsable(requiredCookie: "auth_token"))
        #expect(!WebSession(cookies: [cookie("sessionid", "")]).isUsable(requiredCookie: "sessionid"))
        #expect(!WebSession(cookies: [cookie("sessionid", "x", expires: .now.addingTimeInterval(-1))])
            .isUsable(requiredCookie: "sessionid"))
    }

    @Test func readsValuesByName() {
        let session = WebSession(cookies: [cookie("csrftoken", "xyz")])
        #expect(session.value(named: "csrftoken") == "xyz")
        #expect(session.value(named: "ct0") == nil)
    }
}
