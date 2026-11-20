import Foundation
import Testing
@testable import InstagramMedia

private let reel = #"""
{"gql_data":{"shortcode_media":{"__typename":"GraphVideo","video_url":"https://media.test/reel.mp4","display_url":"https://media.test/reel.jpg","owner":{"username":"someone"},"edge_media_to_caption":{"edges":[{"node":{"text":"  Hello world  "}}]}}}}
"""#

// Wie echte Karussells: Die Kinder tragen kein __typename; Video erkennt man am video_url.
private let carousel = #"""
{"gql_data":{"shortcode_media":{"__typename":"GraphSidecar","edge_sidecar_to_children":{"edges":[
{"node":{"display_url":"https://media.test/1.jpg"}},
{"node":{"display_url":"https://media.test/2.jpg","video_url":"https://media.test/2.mp4"}},
{"node":{"display_url":"https://media.test/1.jpg"}}
]}}}}
"""#

struct EmbedDecoderTests {
    @Test func decodesAReel() throws {
        let post = try InstagramPost.decode(embedHTML: embedHTML(reel))
        #expect(post.media == [.init(kind: .video, url: URL(string: "https://media.test/reel.mp4")!)])
        #expect(post.caption == "Hello world")
        #expect(post.author == "someone")
    }

    @Test func carouselKeepsOrderAndDropsDuplicates() throws {
        let post = try InstagramPost.decode(embedHTML: embedHTML(carousel))
        #expect(post.media.map(\.url.absoluteString) == ["https://media.test/1.jpg", "https://media.test/2.mp4"])
        #expect(post.media.map(\.kind) == [.image, .video])
        #expect(post.caption == nil && post.author == nil)
    }

    @Test func missingContextIsAnError() {
        #expect(throws: (any Error).self) { _ = try InstagramPost.decode(embedHTML: "<html></html>") }
    }
}
