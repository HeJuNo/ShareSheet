import Foundation
import SharesheetCore

public struct XMediaItem: Equatable, Sendable {
    public enum Kind: String, Sendable { case image, video }
    public var kind: Kind
    public var url: URL
    public init(kind: Kind, url: URL) { self.kind = kind; self.url = url }
}

/// Reads a public post from X's public syndication endpoint.
public enum XSyndication {
    /// X ignores this token for public posts (checked 2026-11-20); compute the JS base36 token if it starts validating.
    private static let token = "0"

    static func requestURL(for id: String) -> URL? {
        URL(string: "https://cdn.syndication.twimg.com/tweet-result?id=\(id)&lang=en&token=\(token)")
    }

    public static func decode(_ data: Data) throws -> (media: [XMediaItem], caption: String?) {
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: data) } catch {
            throw XSyndicationError.unreadable
        }
        var items: [XMediaItem] = []
        for detail in payload.mediaDetails ?? [] {
            if let variants = detail.video_info?.variants {
                let videos = variants.compactMap { variant -> (Int, URL)? in
                    guard variant.content_type == "video/mp4", let url = https(variant.url) else { return nil }
                    return (variant.bitrate ?? 0, url)
                }
                if let best = videos.max(by: { $0.0 < $1.0 })?.1 {
                    items.append(.init(kind: .video, url: best))
                    continue
                }
            }
            if let image = https(detail.media_url_https) {
                items.append(.init(kind: .image, url: image))
            }
        }
        if items.isEmpty {
            items = (payload.photos ?? []).compactMap { photo in
                https(photo.url).map { .init(kind: .image, url: $0) }
            }
        }

        var seen: Set<URL> = []
        items = items.filter { seen.insert($0.url).inserted }
        let caption = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (items, caption.flatMap { $0.isEmpty ? nil : $0 })
    }

    private static func https(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), url.scheme?.lowercased() == "https" else { return nil }
        return url
    }
}

enum XSyndicationError: Error, Equatable {
    case unreadable
}

private struct Payload: Decodable {
    let text: String?
    let photos: [Photo]?
    let mediaDetails: [MediaDetail]?
}

private struct Photo: Decodable { let url: String? }

private struct MediaDetail: Decodable {
    let type: String?
    let media_url_https: String?
    let video_info: VideoInfo?
}

private struct VideoInfo: Decodable { let variants: [Variant]? }

private struct Variant: Decodable {
    let content_type: String?
    let bitrate: Int?
    let url: String?
}
