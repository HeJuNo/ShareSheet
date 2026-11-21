import Foundation
import Testing
@testable import InstagramMedia

struct InstagramMediaIDTests {
    @Test func convertsAShortcodeToTheMediaID() {
        #expect(InstagramMediaID.string(for: "DfNDnB4oZut") == "4020885918534704045")
    }

    @Test func rejectsInvalidShortcodes() {
        #expect(InstagramMediaID.string(for: "") == nil)
        #expect(InstagramMediaID.string(for: "abc!") == nil)
        #expect(InstagramMediaID.string(for: String(repeating: "z", count: 12)) == nil)
    }
}
