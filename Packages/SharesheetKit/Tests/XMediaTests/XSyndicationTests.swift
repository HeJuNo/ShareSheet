import Foundation
import Testing
@testable import XMedia

struct XSyndicationTests {
    private func decode(_ json: String) throws -> (media: [XMediaItem], caption: String?) {
        try XSyndication.decode(Data(json.utf8))
    }

    @Test func takesTheHighestBitrateMP4AndTheText() throws {
        let json = #"""
        {"text":"  Hello world  ","mediaDetails":[{"type":"video","video_info":{"variants":[
         {"content_type":"application/x-mpegURL","url":"https://video.twimg.com/x/pl.m3u8"},
         {"content_type":"video/mp4","bitrate":632000,"url":"https://video.twimg.com/x/320.mp4"},
         {"content_type":"video/mp4","bitrate":2176000,"url":"https://video.twimg.com/x/720.mp4"}
        ]}}]}
        """#
        let result = try decode(json)
        #expect(result.media == [.init(kind: .video, url: URL(string: "https://video.twimg.com/x/720.mp4")!)])
        #expect(result.caption == "Hello world")
    }

    @Test func readsMultiplePhotos() throws {
        let json = #"""
        {"text":" pics ","photos":[{"url":"https://pbs.twimg.com/media/A.jpg"},{"url":"https://pbs.twimg.com/media/B.jpg"}]}
        """#
        let result = try decode(json)
        #expect(result.media.map(\.url.absoluteString) == [
            "https://pbs.twimg.com/media/A.jpg", "https://pbs.twimg.com/media/B.jpg",
        ])
        #expect(result.media.allSatisfy { $0.kind == .image })
        #expect(result.caption == "pics")
    }

    @Test func readsAPhotoFromMediaDetails() throws {
        let json = #"""
        {"mediaDetails":[{"type":"photo","media_url_https":"https://pbs.twimg.com/media/C.jpg"}]}
        """#
        #expect(try decode(json).media == [.init(kind: .image, url: URL(string: "https://pbs.twimg.com/media/C.jpg")!)])
    }

    @Test func noMediaIsAnEmptyList() throws {
        #expect(try decode(#"{"text":"text only"}"#).media.isEmpty)
    }

    @Test func aTombstoneHasNoMedia() throws {
        let json = #"{"__typename":"TweetTombstone","tombstone":{"text":"This post is unavailable"}}"#
        #expect(try decode(json).media.isEmpty)
    }

    @Test func ignoresNonHTTPSMedia() throws {
        let json = #"{"photos":[{"url":"http://pbs.twimg.com/media/A.jpg"}]}"#
        #expect(try decode(json).media.isEmpty)
    }

    @Test func rejectsMalformedJSON() {
        #expect(throws: (any Error).self) { _ = try XSyndication.decode(Data("not json".utf8)) }
    }
}
