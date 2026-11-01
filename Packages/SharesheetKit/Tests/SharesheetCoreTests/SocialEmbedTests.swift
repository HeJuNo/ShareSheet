import Foundation
import Testing
@testable import SharesheetCore

struct SocialEmbedTests {
    @Test(arguments: [
        ("https://x.com/imryven/status/2116689928809595172?s=12", SocialEmbed.Platform.x),
        ("https://twitter.com/jack/status/20", .x),
        ("https://www.instagram.com/reel/DfNDnB4oZut/", .instagram),
        ("https://www.facebook.com/somepage/posts/123", .facebook),
        ("https://m.facebook.com/watch/?v=1", .facebook),
        ("https://fb.watch/abc/", .facebook),
    ])
    func recognisesSupportedPosts(link: String, platform: SocialEmbed.Platform) {
        #expect(SocialEmbed.platform(of: URL(string: link)!) == platform)
    }

    @Test(arguments: ["https://x.com/imryven", "https://example.com/x.com/status/1", "ftp://x.com/a/status/1"])
    func ignoresOtherLinks(link: String) {
        #expect(SocialEmbed.platform(of: URL(string: link)!) == nil)
        #expect(SocialEmbed.endpoint(for: URL(string: link)!) == nil)
    }

    @Test func xEndpointAsksForMarkupWithoutScript() throws {
        let endpoint = try #require(SocialEmbed.endpoint(for: URL(string: "https://x.com/a/status/1?s=12")!))
        let components = try #require(URLComponents(url: endpoint, resolvingAgainstBaseURL: false))
        #expect(components.host == "publish.x.com")
        #expect(components.path == "/oembed")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        #expect(query["url"] == "https://x.com/a/status/1?s=12")
        #expect(query["omit_script"] == "1")
    }

    @Test func facebookVideosUseTheVideoEndpoint() throws {
        let video = try #require(SocialEmbed.endpoint(for: URL(string: "https://www.facebook.com/page/videos/42/")!))
        let post = try #require(SocialEmbed.endpoint(for: URL(string: "https://www.facebook.com/page/posts/42")!))
        #expect(video.path() == "/v25.0/oembed_video")
        #expect(post.path() == "/v25.0/oembed_post")
    }

    @Test func decodesTextAndAuthorFromAnXResponse() throws {
        let json = #"""
            {"author_name":"Ryven","html":"<blockquote class=\"twitter-tweet\"><p lang=\"en\" dir=\"ltr\">This is getting scary.<br><br>15 repos &amp; more <a href=\"https://t.co/x\">pic.twitter.com/x</a></p>&mdash; Ryven (@imryven) <a href=\"https://x.com/a\">November 1, 2026</a></blockquote>\n"}
            """#
        let response = try SocialEmbed.decode(Data(json.utf8))
        #expect(response.authorName == "Ryven")
        #expect(SocialEmbed.text(of: response) == "This is getting scary.\n\n15 repos & more pic.twitter.com/x")
    }

    @Test func instagramSkeletonHasNoText() {
        let response = SocialEmbed.Response(html: ##"<blockquote class="instagram-media"><div><a href="#">View this post on Instagram</a></div></blockquote>"##)
        #expect(SocialEmbed.text(of: response) == nil)
    }

    @Test func pageWrapsMarkupWithThePlatformScript() {
        let response = SocialEmbed.Response(html: #"<blockquote class="twitter-tweet"><p>hi</p></blockquote>"#)
        let x = SocialEmbed.page(for: response, platform: .x)
        #expect(x.contains(response.html))
        #expect(x.contains("platform.twitter.com/widgets.js"))
        #expect(x.contains("width=device-width"))
        #expect(!SocialEmbed.page(for: response, platform: .instagram).contains("widgets.js"))
    }
}
