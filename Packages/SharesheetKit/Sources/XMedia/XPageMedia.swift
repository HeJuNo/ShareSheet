import Foundation
import SwiftSoup

/// Reads the main post's media from a signed-in X tweet page.
/// The page embeds each tweet as a JSON string after `value:`; the record is selected by its status id,
/// so quoted posts and page cards cannot contribute media.
public enum XPageMedia {
    public static func decode(html: String, tweetID: String) throws -> (media: [XMediaItem], caption: String?) {
        guard let result = recordResult(in: html, tweetID: tweetID) else {
            // No focal record (login wall or changed layout): no media; never fall back to page-wide URLs.
            return ([], ogDescription(html))
        }
        return (media(from: result), caption(from: result) ?? ogDescription(html))
    }

    private static func recordResult(in html: String, tweetID: String) -> TweetResult? {
        var searchStart = html.startIndex
        while let key = html.range(of: "tweet_result_by_rest_id", range: searchStart..<html.endIndex) {
            if let value = html.range(of: "value:\"", options: .backwards, range: html.startIndex..<key.lowerBound) {
                let quote = html.index(before: value.upperBound)
                if let end = endOfStringLiteral(in: html, from: quote) {
                    let literal = String(html[quote...end])
                    if let unescaped = try? JSONDecoder().decode(String.self, from: Data(literal.utf8)),
                       let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(unescaped.utf8)),
                       let record = envelope.data?.tweetResultByRestID,
                       record.restID == tweetID || record.result?.restID == tweetID {
                        return record.result
                    }
                }
            }
            searchStart = key.upperBound
        }
        return nil
    }

    private static func endOfStringLiteral(in html: String, from quote: String.Index) -> String.Index? {
        var index = html.index(after: quote)
        var escaped = false
        while index < html.endIndex {
            let character = html[index]
            if escaped { escaped = false }
            else if character == "\\" { escaped = true }
            else if character == "\"" { return index }
            index = html.index(after: index)
        }
        return nil
    }

    private static func media(from result: TweetResult) -> [XMediaItem] {
        let entities = result.mediaEntities ?? result.legacy?.extendedEntities?.media ?? []
        var items: [XMediaItem] = []
        for entity in entities {
            if let variants = entity.videoInfo?.variants {
                let best = variants.compactMap { variant -> (Int, URL)? in
                    guard variant.contentType == "video/mp4", let url = https(variant.url) else { return nil }
                    return (variant.bitrate ?? 0, url)
                }.max(by: { $0.0 < $1.0 })?.1
                if let best { items.append(.init(kind: .video, url: best)) }
                continue
            }
            if entity.type == "photo", let image = photoURL(entity.mediaURL) {
                items.append(.init(kind: .image, url: image))
            }
        }
        var seen: Set<URL> = []
        return items.filter { seen.insert($0.url).inserted }
    }

    private static func caption(from result: TweetResult) -> String? {
        let text = result.noteTweet?.noteTweetResults?.result?.text ?? result.legacy?.fullText
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func ogDescription(_ html: String) -> String? {
        guard let doc = try? SwiftSoup.parse(html),
              let text = try? doc.select("meta[property=og:description]").first()?.attr("content")
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func photoURL(_ raw: String?) -> URL? {
        guard let raw, let id = firstMatch(#"pbs\.twimg\.com/media/([A-Za-z0-9_-]+)"#, in: raw) else { return nil }
        return URL(string: "https://pbs.twimg.com/media/\(id)?format=jpg&name=large")
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    private static func https(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), url.scheme?.lowercased() == "https" else { return nil }
        return url
    }
}

enum XPageMediaError: Error, Equatable {
    case unreadable
}

private struct Envelope: Decodable {
    let data: DataField?
}

private struct DataField: Decodable {
    let tweetResultByRestID: Record?

    enum CodingKeys: String, CodingKey {
        case tweetResultByRestID = "tweet_result_by_rest_id"
    }
}

private struct Record: Decodable {
    let restID: String?
    let result: TweetResult?

    enum CodingKeys: String, CodingKey {
        case restID = "rest_id"
        case result
    }
}

private struct TweetResult: Decodable {
    let restID: String?
    let mediaEntities: [MediaEntity]?
    let legacy: Legacy?
    let noteTweet: NoteTweet?

    enum CodingKeys: String, CodingKey {
        case restID = "rest_id"
        case mediaEntities = "media_entities2"
        case legacy
        case noteTweet = "note_tweet"
    }
}

private struct Legacy: Decodable {
    let fullText: String?
    let extendedEntities: ExtendedEntities?

    enum CodingKeys: String, CodingKey {
        case fullText = "full_text"
        case extendedEntities = "extended_entities"
    }
}

private struct ExtendedEntities: Decodable {
    let media: [MediaEntity]?
}

private struct NoteTweet: Decodable {
    let noteTweetResults: NoteResults?

    enum CodingKeys: String, CodingKey {
        case noteTweetResults = "note_tweet_results"
    }
}

private struct NoteResults: Decodable {
    let result: NoteText?
}

private struct NoteText: Decodable {
    let text: String?
}

private struct MediaEntity: Decodable {
    let type: String?
    let mediaURL: String?
    let videoInfo: VideoInfo?

    enum CodingKeys: String, CodingKey {
        case type
        case mediaURL = "media_url_https"
        case videoInfo = "video_info"
    }
}

private struct VideoInfo: Decodable {
    let variants: [Variant]?
}

private struct Variant: Decodable {
    let contentType: String?
    let bitrate: Int?
    let url: String?

    enum CodingKeys: String, CodingKey {
        case contentType = "content_type"
        case bitrate
        case url
    }
}
