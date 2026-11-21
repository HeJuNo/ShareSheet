import Foundation
import Testing
@testable import SpotifyMedia

struct SpotifyTrackIDTests {
    @Test(arguments: [
        ("https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT", "4cOdK2wGLETKBW3PvgPWqT"),
        ("https://open.spotify.com/intl-de/track/4cOdK2wGLETKBW3PvgPWqT?si=abc123", "4cOdK2wGLETKBW3PvgPWqT"),
        ("https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT/?si=abc", "4cOdK2wGLETKBW3PvgPWqT"),
    ])
    func readsTheID(link: String, id: String) {
        #expect(SpotifyTrackID.string(from: URL(string: link)!) == id)
    }

    @Test(arguments: [
        "https://open.spotify.com/album/4cOdK2wGLETKBW3PvgPWqT",
        "https://open.spotify.com/playlist/4cOdK2wGLETKBW3PvgPWqT",
        "https://open.spotify.com/track/",
        "https://open.spotify.com/track/short",
        "https://example.com/track/4cOdK2wGLETKBW3PvgPWqT",
        "https://open.spotify.com/artist/4cOdK2wGLETKBW3PvgPWqT",
    ])
    func ignoresOthers(link: String) {
        #expect(SpotifyTrackID.string(from: URL(string: link)!) == nil)
    }
}
