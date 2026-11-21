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
        ("https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT?si=abc", .spotify),
        ("https://open.spotify.com/intl-de/track/4cOdK2wGLETKBW3PvgPWqT", .spotify),
    ])
    func recognisesSupportedPosts(link: String, platform: SocialEmbed.Platform) {
        #expect(SocialEmbed.platform(of: URL(string: link)!) == platform)
    }

    @Test(arguments: [
        "https://x.com/imryven", "https://example.com/x.com/status/1", "ftp://x.com/a/status/1",
        "https://open.spotify.com/album/4cOdK2wGLETKBW3PvgPWqT",
    ])
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

    @Test func spotifyUsesItsOEmbedEndpoint() throws {
        let endpoint = try #require(
            SocialEmbed.endpoint(for: URL(string: "https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT")!))
        let components = try #require(URLComponents(url: endpoint, resolvingAgainstBaseURL: false))
        #expect(components.host == "open.spotify.com")
        #expect(components.path == "/oembed")
        #expect(components.queryItems?.first?.value == "https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT")
    }

    @Test func onlyFacebookShareLinksNeedResolving() {
        #expect(SocialEmbed.needsResolving(URL(string: "https://www.facebook.com/share/1EaxwpwnkH/?mibextid=wwXIfr")!))
        #expect(SocialEmbed.needsResolving(URL(string: "https://www.facebook.com/share/v/abc/")!))
        #expect(!SocialEmbed.needsResolving(URL(string: "https://www.facebook.com/photo.php?fbid=1")!))
        #expect(!SocialEmbed.needsResolving(URL(string: "https://x.com/a/status/1")!))
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

    @Test func spotifyPageShowsTheTrackCardInsteadOfAnEmptyFrame() throws {
        let json = #"""
        {"html":"<iframe src=\"https://open.spotify.com/embed/track/4cOdK2wGLETKBW3PvgPWqT\"></iframe>",
         "title":"Why?","thumbnail_url":"https://image-cdn-fa.spotifycdn.com/image/cover"}
        """#
        let response = try SocialEmbed.decode(Data(json.utf8))
        let page = SocialEmbed.page(for: response, platform: .spotify)
        #expect(page.contains("https://image-cdn-fa.spotifycdn.com/image/cover"))
        #expect(page.contains("Why?"))
        #expect(!page.contains("<iframe"))
    }

    @Test func spotifyCardEscapesTheTitle() throws {
        let response = SocialEmbed.Response(
            html: "", title: "A <b> & \"B\"", thumbnailURL: URL(string: "https://image-cdn-fa.spotifycdn.com/i"))
        let page = SocialEmbed.page(for: response, platform: .spotify)
        #expect(page.contains("A &lt;b&gt; &amp; &quot;B&quot;"))
        #expect(!page.contains("A <b> & \"B\""))
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
