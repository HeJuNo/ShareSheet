import Foundation
import Testing
@testable import SpotifyMedia

struct SpotifyEmbedTests {
    /// The embed page carries its data as JSON in a `__NEXT_DATA__` script.
    private func page(entity: String) -> String {
        let next = #"""
        {"props":{"pageProps":{"state":{"data":{"entity":\#(entity)}}}}}
        """#
        return "<html><head></head><body><script id=\"__NEXT_DATA__\" type=\"application/json\">\(next)</script></body></html>"
    }

    private let track = #"""
    {"type":"track","name":"Never Gonna Give You Up","title":"Never Gonna Give You Up",
     "artists":[{"name":"Rick Astley","uri":"spotify:artist:1"}],
     "audioPreview":{"url":"https://p.scdn.co/mp3-preview/abc"},
     "visualIdentity":{"image":[
       {"url":"https://image-cdn-fa.spotifycdn.com/image/small","maxWidth":300,"maxHeight":300},
       {"url":"https://image-cdn-fa.spotifycdn.com/image/large","maxWidth":640,"maxHeight":640}
     ]}}
    """#

    @Test func readsTheCoverAndThePreviewClip() throws {
        let result = try SpotifyEmbed.decode(html: page(entity: track))
        #expect(result.media == [
            .init(kind: .image, url: URL(string: "https://image-cdn-fa.spotifycdn.com/image/large")!),
            .init(kind: .audio, url: URL(string: "https://p.scdn.co/mp3-preview/abc")!),
        ])
        #expect(result.caption == "Never Gonna Give You Up – Rick Astley")
    }

    @Test func aTrackWithoutPreviewKeepsTheCover() throws {
        let entity = #"{"name":"Song","artists":[{"name":"A"}],"visualIdentity":{"image":[{"url":"https://image-cdn-fa.spotifycdn.com/image/c","maxWidth":1}]}}"#
        let result = try SpotifyEmbed.decode(html: page(entity: entity))
        #expect(result.media == [.init(kind: .image, url: URL(string: "https://image-cdn-fa.spotifycdn.com/image/c")!)])
        #expect(result.caption == "Song – A")
    }

    @Test func aTrackWithoutCoverKeepsThePreview() throws {
        let entity = #"{"name":"Song","artists":[{"name":"A"}],"audioPreview":{"url":"https://p.scdn.co/mp3-preview/x"}}"#
        let result = try SpotifyEmbed.decode(html: page(entity: entity))
        #expect(result.media == [.init(kind: .audio, url: URL(string: "https://p.scdn.co/mp3-preview/x")!)])
    }

    @Test func joinsSeveralArtists() throws {
        let entity = #"{"name":"Song","artists":[{"name":"A"},{"name":"B"}]}"#
        #expect(try SpotifyEmbed.decode(html: page(entity: entity)).caption == "Song – A, B")
    }

    @Test func dropsNonHTTPSMedia() throws {
        let entity = #"{"name":"Song","audioPreview":{"url":"http://p.scdn.co/x"},"visualIdentity":{"image":[{"url":"http://image-cdn-fa.spotifycdn.com/i"}]}}"#
        #expect(try SpotifyEmbed.decode(html: page(entity: entity)).media.isEmpty)
    }

    @Test func aPageWithoutTheDataThrows() {
        #expect(throws: (any Error).self) { _ = try SpotifyEmbed.decode(html: "<html><body>no script</body></html>") }
    }

    @Test func aPageWithoutEntityDataThrows() {
        #expect(throws: (any Error).self) { _ = try SpotifyEmbed.decode(html: page(entity: "{}")) }
    }
}
