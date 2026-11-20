import Foundation

extension InstagramPost {
    enum DecodeError: Error, Equatable {
        case missingContext
        case unreadable
    }

    /// Liest die Medien eines öffentlichen Beitrags aus der Einbettungsseite.
    public static func decode(embedHTML: String) throws -> Post {
        let data = try contextJSON(in: embedHTML)
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: data) } catch { throw DecodeError.unreadable }
        guard let node = payload.gql_data?.shortcode_media else { throw DecodeError.unreadable }

        let nodes = node.edge_sidecar_to_children?.edges?.map(\.node) ?? [node]
        var seen: Set<URL> = []
        var media: [Media] = []
        for child in nodes {
            let item: Media?
            if let raw = child.video_url, let url = httpsURL(raw) {
                item = Media(kind: .video, url: url)
            } else if let raw = child.display_url, let url = httpsURL(raw) {
                item = Media(kind: .image, url: url)
            } else {
                item = nil
            }
            if let item, seen.insert(item.url).inserted { media.append(item) }
        }

        let caption = node.edge_media_to_caption?.edges?.first?.node.text?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Post(
            media: media,
            caption: caption.flatMap { $0.isEmpty ? nil : $0 },
            author: node.owner?.username)
    }

    /// Das String-Literal hinter `"contextJSON":` finden und entschlüsseln.
    private static func contextJSON(in html: String) throws -> Data {
        guard let key = html.range(of: "\"contextJSON\"") else { throw DecodeError.missingContext }
        var index = key.upperBound
        while index < html.endIndex, html[index].isWhitespace { index = html.index(after: index) }
        guard index < html.endIndex, html[index] == ":" else { throw DecodeError.missingContext }
        index = html.index(after: index)
        while index < html.endIndex, html[index].isWhitespace { index = html.index(after: index) }
        guard index < html.endIndex, html[index] == "\"" else { throw DecodeError.missingContext }

        let start = index
        var escaped = false
        index = html.index(after: index)
        while index < html.endIndex {
            let character = html[index]
            if escaped { escaped = false }
            else if character == "\\" { escaped = true }
            else if character == "\"" { break }
            index = html.index(after: index)
        }
        guard index < html.endIndex else { throw DecodeError.missingContext }

        let literal = String(html[start...index])
        guard let unescaped = try? JSONDecoder().decode(String.self, from: Data(literal.utf8)),
              let data = unescaped.data(using: .utf8)
        else { throw DecodeError.unreadable }
        return data
    }

    private static func httpsURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https" else { return nil }
        return url
    }
}

private struct Payload: Decodable { let gql_data: GQL? }
private struct GQL: Decodable { let shortcode_media: Node? }

private struct Node: Decodable {
    let display_url: String?
    let video_url: String?
    let owner: Owner?
    let edge_media_to_caption: Captions?
    let edge_sidecar_to_children: Children?
}

private struct Owner: Decodable { let username: String? }
private struct Captions: Decodable { let edges: [CaptionEdge]? }
private struct CaptionEdge: Decodable { let node: CaptionNode }
private struct CaptionNode: Decodable { let text: String? }
private struct Children: Decodable { let edges: [ChildEdge]? }
private struct ChildEdge: Decodable { let node: Node }
