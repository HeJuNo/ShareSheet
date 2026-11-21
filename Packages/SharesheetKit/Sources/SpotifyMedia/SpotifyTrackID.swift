import Foundation
import SharesheetCore

/// The base62 id of an open.spotify.com track link.
public enum SpotifyTrackID {
    public static func string(from url: URL) -> String? {
        guard url.isWebPage, var host = url.host()?.lowercased() else { return nil }
        for prefix in ["www.", "open.", "play."] where host.hasPrefix(prefix) { host.removeFirst(prefix.count) }
        guard host == "spotify.com" else { return nil }
        let parts = url.path().split(separator: "/").map(String.init)
        guard let track = parts.firstIndex(of: "track"), parts.indices.contains(track + 1) else { return nil }
        let id = parts[track + 1]
        guard id.count == 22, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return id
    }
}
