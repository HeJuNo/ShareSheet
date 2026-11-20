import Foundation

enum InstagramAPIError: Error, Equatable {
    case noItems(String)
    case unreadable
}

/// Decodes the response of `/api/v1/media/{id}/info/` from a signed-in web session.
enum InstagramAPI {
    static func decode(_ data: Data) throws -> (media: [InstagramPost.Media], caption: String?) {
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: data) } catch {
            throw InstagramAPIError.unreadable
        }
        if payload.status == "fail" {
            throw InstagramAPIError.noItems(payload.message ?? "status fail")
        }
        guard let item = payload.items?.first else {
            throw InstagramAPIError.noItems(payload.message ?? "no items")
        }

        var seen: Set<URL> = []
        var result: [InstagramPost.Media] = []
        for candidate in media(from: item) where seen.insert(candidate.url).inserted {
            result.append(candidate)
        }
        let caption = item.caption?.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (result, caption.flatMap { $0.isEmpty ? nil : $0 })
    }

    private static func media(from item: Item) -> [InstagramPost.Media] {
        if let children = item.carousel_media, !children.isEmpty {
            return children.flatMap { media(from: $0) }
        }
        if let video = item.video_versions?.compactMap({ https($0.url) }).first {
            return [.init(kind: .video, url: video)]
        }
        let images = (item.image_versions2?.candidates ?? []).compactMap { candidate -> (Int, URL)? in
            guard let url = https(candidate.url) else { return nil }
            return (candidate.width ?? 0, url)
        }
        if let image = images.max(by: { $0.0 < $1.0 })?.1 {
            return [.init(kind: .image, url: image)]
        }
        return []
    }

    private static func https(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), url.scheme?.lowercased() == "https" else { return nil }
        return url
    }
}

private struct Payload: Decodable {
    let status: String?
    let message: String?
    let items: [Item]?
}

private struct Item: Decodable {
    let image_versions2: Images?
    let video_versions: [Video]?
    let carousel_media: [Item]?
    let caption: Caption?
}

private struct Images: Decodable { let candidates: [Image]? }
private struct Image: Decodable { let url: String?; let width: Int? }
private struct Video: Decodable { let url: String?; let width: Int? }
private struct Caption: Decodable { let text: String? }
