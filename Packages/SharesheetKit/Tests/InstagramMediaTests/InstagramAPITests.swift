import Foundation
import Testing
@testable import InstagramMedia

struct InstagramAPITests {
    @Test func readsTheLargestImageCandidateAndTheCaption() throws {
        let json = #"""
        {"status":"ok","items":[{"media_type":1,
         "image_versions2":{"candidates":[{"url":"https://cdn.test/small.jpg","width":640},{"url":"https://cdn.test/large.jpg","width":1080}]},
         "caption":{"text":"  Hello world  "}}]}
        """#
        let result = try InstagramAPI.decode(Data(json.utf8))
        #expect(result.media == [.init(kind: .image, url: URL(string: "https://cdn.test/large.jpg")!)])
        #expect(result.caption == "Hello world")
    }

    @Test func readsAVideoVersion() throws {
        let json = #"""
        {"items":[{"media_type":2,"video_versions":[{"url":"https://cdn.test/v.mp4","width":1080}],
         "image_versions2":{"candidates":[{"url":"https://cdn.test/poster.jpg","width":1080}]}}]}
        """#
        let result = try InstagramAPI.decode(Data(json.utf8))
        #expect(result.media == [.init(kind: .video, url: URL(string: "https://cdn.test/v.mp4")!)])
    }

    @Test func keepsCarouselOrderAndDropsDuplicates() throws {
        let json = #"""
        {"items":[{"media_type":8,"carousel_media":[
         {"image_versions2":{"candidates":[{"url":"https://cdn.test/1.jpg","width":1080}]}},
         {"video_versions":[{"url":"https://cdn.test/2.mp4","width":1080}]},
         {"image_versions2":{"candidates":[{"url":"https://cdn.test/1.jpg","width":1080}]}}
        ]}]}
        """#
        let result = try InstagramAPI.decode(Data(json.utf8))
        #expect(result.media.map(\.url.absoluteString) == ["https://cdn.test/1.jpg", "https://cdn.test/2.mp4"])
        #expect(result.media.map(\.kind) == [.image, .video])
    }

    @Test func rejectsAFailedStatus() {
        let json = #"{"status":"fail","message":"login_required"}"#
        #expect(throws: (any Error).self) { _ = try InstagramAPI.decode(Data(json.utf8)) }
    }

    @Test func rejectsEmptyItems() {
        #expect(throws: (any Error).self) { _ = try InstagramAPI.decode(Data(#"{"items":[]}"#.utf8)) }
    }

    @Test func rejectsMalformedJSON() {
        #expect(throws: (any Error).self) { _ = try InstagramAPI.decode(Data("not json".utf8)) }
    }

    @Test func ignoresNonHTTPSMedia() throws {
        let json = #"""
        {"items":[{"image_versions2":{"candidates":[{"url":"http://cdn.test/insecure.jpg","width":1080}]}}]}
        """#
        #expect(try InstagramAPI.decode(Data(json.utf8)).media.isEmpty)
    }
}
