import Foundation
import Testing
@testable import XMedia

struct XPageMediaTests {
    private let videoHTML = #"""
    <html><head>
    <meta property="og:description" content="Hello &amp; welcome"/>
    <meta property="og:image" content="https://pbs.twimg.com/amplify_video_thumb/111/img/poster.jpg"/>
    </head><body>
    <script>{"main":"{\"video_info\":{\"variants\":[
    {\"content_type\":\"video/mp4\",\"bitrate\":632000,\"url\":\"https:\/\/video.twimg.com\/amplify_video\/111\/vid\/avc1\/320x400\/a.mp4?tag=1\"},
    {\"content_type\":\"video/mp4\",\"bitrate\":2176000,\"url\":\"https:\/\/video.twimg.com\/amplify_video\/111\/vid\/avc1\/720x900\/b.mp4?tag=1\"}
    ]}}","quoted":"{\"video_info\":{\"variants\":[
    {\"content_type\":\"video/mp4\",\"url\":\"https:\/\/video.twimg.com\/amplify_video\/222\/vid\/avc1\/1080x1350\/c.mp4?tag=1\"}
    ]}}"}</script>
    </body></html>
    """#

    private let photoHTML = #"""
    <html><head>
    <meta property="og:description" content="Pictures"/>
    <meta property="og:image" content="https://pbs.twimg.com/media/AAA?format=webp&amp;name=medium"/>
    </head><body>
    <script>{"a":"https:\/\/pbs.twimg.com\/media\/AAA.jpg","b":"https:\/\/pbs.twimg.com\/media\/BBB.jpg","p":"https:\/\/pbs.twimg.com\/profile_images\/PP.jpg"}</script>
    </body></html>
    """#

    @Test func readsTheMainVideoAndNotAQuotedOne() throws {
        let result = try XPageMedia.decode(html: videoHTML, tweetID: "123")
        #expect(result.media.map(\.url.absoluteString) == [
            "https://video.twimg.com/amplify_video/111/vid/avc1/720x900/b.mp4?tag=1",
        ])
        #expect(result.media.first?.kind == .video)
        #expect(result.caption == "Hello & welcome")
    }

    @Test func readsPhotosAndIgnoresProfileImages() throws {
        let result = try XPageMedia.decode(html: photoHTML, tweetID: "123")
        #expect(result.media.map(\.url.absoluteString) == [
            "https://pbs.twimg.com/media/AAA?format=jpg&name=large",
            "https://pbs.twimg.com/media/BBB?format=jpg&name=large",
        ])
        #expect(result.media.allSatisfy { $0.kind == .image })
    }

    @Test func aPageWithoutMediaReturnsNothing() throws {
        let result = try XPageMedia.decode(
            html: #"<html><head><meta property="og:description" content="x"/></head></html>"#, tweetID: "123")
        #expect(result.media.isEmpty)
        #expect(result.caption == "x")
    }
}
