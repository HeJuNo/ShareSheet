import Foundation
import Testing
@testable import XMedia

struct XTweetIDTests {
    @Test(arguments: [
        ("https://x.com/user/status/1234567890", "1234567890"),
        ("https://twitter.com/user/status/42?s=20", "42"),
        ("https://mobile.x.com/user/status/99", "99"),
        ("https://x.com/i/status/7", "7"),
        ("https://x.com/user/status/123/photo/1", "123"),
    ])
    func readsTheID(link: String, id: String) {
        #expect(XTweetID.string(from: URL(string: link)!) == id)
    }

    @Test(arguments: [
        "https://x.com/user",
        "https://x.com/user/status/",
        "https://x.com/user/status/abc",
        "https://example.com/user/status/1",
        "https://x.com/user/likes",
    ])
    func ignoresOthers(link: String) {
        #expect(XTweetID.string(from: URL(string: link)!) == nil)
    }
}
