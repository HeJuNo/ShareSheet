import Foundation

public struct SpotifyMediaItem: Equatable, Sendable {
    public enum Kind: String, Sendable { case image, audio }
    public var kind: Kind
    public var url: URL
    public init(kind: Kind, url: URL) { self.kind = kind; self.url = url }
}

/// Reads a track's cover and Spotify's official preview clip from the embed page.
public enum SpotifyEmbed {
    public static func decode(html: String) throws -> (media: [SpotifyMediaItem], caption: String?) {
        guard let json = nextData(in: html),
              let page = try? JSONDecoder().decode(Page.self, from: Data(json.utf8))
        else { throw SpotifyEmbedError.unreadable }
        let entity = page.props.pageProps.state.data.entity
        guard entity.title != nil || entity.name != nil else { throw SpotifyEmbedError.unreadable }
        var media: [SpotifyMediaItem] = []
        if let artwork = largestArtwork(entity.visualIdentity?.image) {
            media.append(.init(kind: .image, url: artwork))
        }
        if let preview = https(entity.audioPreview?.url) {
            media.append(.init(kind: .audio, url: preview))
        }
        return (media, caption(entity))
    }

    private static func nextData(in html: String) -> String? {
        guard let regex = try? NSRegularExpression(
                  pattern: #"<script[^>]*id="__NEXT_DATA__"[^>]*>(.*?)</script>"#,
                  options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html)
        else { return nil }
        return String(html[range])
    }

    private static func largestArtwork(_ images: [Artwork]?) -> URL? {
        (images ?? [])
            .compactMap { image in https(image.url).map { (image.maxWidth ?? image.maxHeight ?? 0, $0) } }
            .max(by: { $0.0 < $1.0 })?.1
    }

    private static func caption(_ entity: Entity) -> String? {
        let title = (entity.title ?? entity.name)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let artists = (entity.artists ?? []).compactMap {
            $0.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard let title, !title.isEmpty else { return nil }
        return artists.isEmpty ? title : "\(title) – \(artists.joined(separator: ", "))"
    }

    private static func https(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), url.scheme?.lowercased() == "https" else { return nil }
        return url
    }
}

enum SpotifyEmbedError: Error, Equatable {
    case unreadable
}

private struct Page: Decodable {
    let props: Props
}

private struct Props: Decodable {
    let pageProps: PageProps
}

private struct PageProps: Decodable {
    let state: State
}

private struct State: Decodable {
    let data: DataField
}

private struct DataField: Decodable {
    let entity: Entity
}

private struct Entity: Decodable {
    let name: String?
    let title: String?
    let artists: [Artist]?
    let audioPreview: AudioPreview?
    let visualIdentity: VisualIdentity?
}

private struct Artist: Decodable {
    let name: String?
}

private struct AudioPreview: Decodable {
    let url: String?
}

private struct VisualIdentity: Decodable {
    let image: [Artwork]?
}

private struct Artwork: Decodable {
    let url: String?
    let maxWidth: Int?
    let maxHeight: Int?
}
