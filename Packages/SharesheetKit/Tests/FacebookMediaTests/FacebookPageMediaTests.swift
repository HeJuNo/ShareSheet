import Foundation
import Testing
@testable import FacebookMedia

struct FacebookPageMediaTests {
    @Test func readsTheHighQualityVideoAndIgnoresItsPoster() throws {
        let html = #"""
        <html><head>
        <meta property="og:description" content="A clip &amp; more">
        <meta property="og:image" content="https://scontent.xx.fbcdn.net/v/t39.30808-6/poster.jpg">
        </head><body>
        <script>{"browser_native_sd_url":"https:\/\/video.xx.fbcdn.net\/v\/t42.1790-2\/sd.mp4?efg=abc",
        "browser_native_hd_url":"https:\/\/video.xx.fbcdn.net\/v\/t42.1790-2\/hd.mp4?efg=abc"}</script>
        </body></html>
        """#

        let result = try FacebookPageMedia.decode(html: html)
        #expect(result.media == [
            .init(kind: .video, url: URL(string: "https://video.xx.fbcdn.net/v/t42.1790-2/hd.mp4?efg=abc")!),
        ])
        #expect(result.caption == "A clip & more")
    }

    @Test func readsEveryPhotoAndDropsTheDuplicateCover() throws {
        let html = #"""
        <html><head>
        <meta property="og:image" content="https://scontent.xx.fbcdn.net/v/t39.30808-6/first.jpg?_nc_cat=1&amp;stp=a">
        </head><body>
        <script>[{"photo_image_url":"https:\/\/scontent.xx.fbcdn.net\/v\/t39.30808-6\/first.jpg?_nc_cat=1"},
        {"photo_image_url":"https:\/\/scontent.xx.fbcdn.net\/v\/t39.30808-6\/second.jpg?_nc_cat=2"}]</script>
        </body></html>
        """#

        let result = try FacebookPageMedia.decode(html: html)
        #expect(result.media.map(\.url.absoluteString) == [
            "https://scontent.xx.fbcdn.net/v/t39.30808-6/first.jpg?_nc_cat=1",
            "https://scontent.xx.fbcdn.net/v/t39.30808-6/second.jpg?_nc_cat=2",
        ])
    }

    @Test func usesTheCoverWhenThePageListsNoPhotos() throws {
        let html = #"""
        <html><head><meta property="og:image" content="https://scontent.xx.fbcdn.net/v/t39.30808-6/only.jpg"></head></html>
        """#
        #expect(try FacebookPageMedia.decode(html: html).media == [
            .init(kind: .image, url: URL(string: "https://scontent.xx.fbcdn.net/v/t39.30808-6/only.jpg")!),
        ])
    }

    @Test func ignoresForeignMediaURLs() throws {
        let html = #"""
        <html><head><meta property="og:image" content="https://example.com/x.jpg"></head>
        <body><script>{"photo_image_url":"https:\/\/example.com\/y.jpg",
        "browser_native_hd_url":"https:\/\/example.com\/z.mp4"}</script></body></html>
        """#
        #expect(try FacebookPageMedia.decode(html: html).media.isEmpty)
    }

    @Test func aLoginPageHasNoMediaAndNoGenericCaption() throws {
        let html = #"""
        <html><head><title>Log into Facebook</title>
        <meta property="og:description" content="Log into Facebook to start sharing and connecting."></head>
        <body><div id="login_form"></div></body></html>
        """#
        let result = try FacebookPageMedia.decode(html: html)
        #expect(result.media.isEmpty)
        #expect(result.caption == nil)
    }

    @Test func readsTheDescriptionAsTheCaption() throws {
        let html = #"""
        <html><head><meta property="og:description" content="Hello from a page"></head></html>
        """#
        #expect(try FacebookPageMedia.decode(html: html).caption == "Hello from a page")
    }
}
