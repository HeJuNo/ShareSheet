import Foundation
import Testing
@testable import XMedia

struct XPageMediaTests {
    /// A page shaped like X's relay payload: the tweet record is a JSON string after `value:`.
    private func page(tweetID: String, media: String, caption: String, extra: String = "") -> String {
        let record = #"""
        {"data":{"tweet_result_by_rest_id":{"id":"x","rest_id":"\#(tweetID)","result":{
        "rest_id":"\#(tweetID)","media_entities2":\#(media),
        "legacy":{"full_text":"\#(caption)"},
        "quoted_tweet_results":{"result":{"legacy":{"extended_entities":{"media":[
        {"type":"photo","media_url_https":"https://pbs.twimg.com/media/QUOTED.jpg"}]}}}}}}}}
        """#
        let escaped = String(decoding: try! JSONEncoder().encode(record), as: UTF8.self)
        return #"""
        <html><head>
        <meta property="og:description" content="Fallback"/>
        <meta property="og:image" content="https://pbs.twimg.com/profile_images/PP.jpg"/>
        </head><body>
        <script>value:\#(escaped)</script>
        \#(extra)
        </body></html>
        """#
    }

    @Test func readsOnlyTheMainPostsVideo() throws {
        let media = #"""
        [{"type":"video","media_url_https":"https://pbs.twimg.com/amplify_video_thumb/111/img/p.jpg","video_info":{"variants":[
        {"content_type":"video/mp4","bitrate":1,"url":"https://video.twimg.com/x/320.mp4"},
        {"content_type":"video/mp4","bitrate":2,"url":"https://video.twimg.com/x/720.mp4"}
        ]}}]
        """#
        let html = page(tweetID: "123", media: media, caption: "Hello",
                        extra: #"<img src="https://pbs.twimg.com/media/FOREIGN.jpg">"#)

        let result = try XPageMedia.decode(html: html, tweetID: "123")
        #expect(result.media.map(\.url.absoluteString) == ["https://video.twimg.com/x/720.mp4"])
        #expect(result.caption == "Hello")
    }

    @Test func readsOnlyTheMainPostsPhotosAtLargeSize() throws {
        let media = #"""
        [{"type":"photo","media_url_https":"https://pbs.twimg.com/media/AAA?format=webp&name=medium"},
         {"type":"photo","media_url_https":"https://pbs.twimg.com/media/BBB.jpg"}]
        """#
        let html = page(tweetID: "123", media: media, caption: "Pictures",
                        extra: #"<img src="https://pbs.twimg.com/media/FOREIGN.jpg">"#)

        let result = try XPageMedia.decode(html: html, tweetID: "123")
        #expect(result.media.map(\.url.absoluteString) == [
            "https://pbs.twimg.com/media/AAA?format=jpg&name=large",
            "https://pbs.twimg.com/media/BBB?format=jpg&name=large",
        ])
    }

    @Test func aTextOnlyPostTakesNoMediaFromThePage() throws {
        let html = page(tweetID: "123", media: "[]", caption: "Just text",
                        extra: #"<img src="https://pbs.twimg.com/media/FOREIGN.jpg">"#)

        let result = try XPageMedia.decode(html: html, tweetID: "123")
        #expect(result.media.isEmpty)
        #expect(result.caption == "Just text")
    }

    @Test func aVideoWithoutMP4VariantsIsNotSavedAsItsPoster() throws {
        let media = #"""
        [{"type":"video","media_url_https":"https://pbs.twimg.com/ext_tw_video_thumb/111/p.jpg",
          "video_info":{"variants":[{"content_type":"application/x-mpegURL","url":"https://video.twimg.com/x/pl.m3u8"}]}}]
        """#
        #expect(try XPageMedia.decode(html: page(tweetID: "123", media: media, caption: "x"), tweetID: "123")
            .media.isEmpty)
    }

    @Test func aPageWithoutTheTweetRecordHasNoMedia() throws {
        let result = try XPageMedia.decode(
            html: #"<html><head><meta property="og:image" content="https://pbs.twimg.com/media/FOREIGN.jpg"/></head></html>"#,
            tweetID: "123")
        #expect(result.media.isEmpty)
    }
}
