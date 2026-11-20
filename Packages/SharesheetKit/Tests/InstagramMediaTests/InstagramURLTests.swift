import Foundation
import Testing
@testable import InstagramMedia

struct InstagramURLTests {
    @Test(arguments: [
        ("https://www.instagram.com/reel/DfNDnB4oZut/?igsh=abc", "DfNDnB4oZut"),
        ("https://instagram.com/p/C1a2b3c/", "C1a2b3c"),
        ("https://m.instagram.com/reels/ABC_123/", "ABC_123"),
        ("https://www.instagram.com/tv/Tv-123/", "Tv-123"),
    ])
    func readsTheShortcode(link: String, shortcode: String) {
        #expect(InstagramPost.shortcode(in: URL(string: link)!) == shortcode)
    }

    @Test(arguments: [
        "https://www.instagram.com/someuser/",
        "https://www.instagram.com/stories/someuser/123/",
        "https://www.instagram.com/explore/tags/swift/",
        "https://example.com/p/C1a2b3c/",
        "https://www.instagram.com/p/",
    ])
    func ignoresEverythingElse(link: String) {
        #expect(InstagramPost.shortcode(in: URL(string: link)!) == nil)
    }

    @Test func buildsThePublicEmbedAddress() {
        let url = URL(string: "https://m.instagram.com/reels/DfNDnB4oZut/?igsh=abc")!
        #expect(InstagramPost.embedURL(for: url)?.absoluteString
            == "https://www.instagram.com/reel/DfNDnB4oZut/embed/captioned/")
    }
}
