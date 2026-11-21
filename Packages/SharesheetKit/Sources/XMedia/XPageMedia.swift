import Foundation
import SwiftSoup

/// Reads the main post's media from a signed-in X tweet page.
public enum XPageMedia {
    public static func decode(html: String, tweetID: String) throws -> (media: [XMediaItem], caption: String?) {
        let doc: Document
        do { doc = try SwiftSoup.parse(html) } catch { throw XPageMediaError.unreadable }

        func meta(_ property: String) -> String? {
            ((try? doc.select("meta[property=\(property)]").first()?.attr("content")) ?? nil)
        }

        let caption = meta("og:description")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let ogImage = meta("og:image")
        let unescaped = html.replacingOccurrences(of: "\\/", with: "/")

        var media: [XMediaItem] = []
        if let ogImage, let videoID = videoThumbID(ogImage) {
            let urls = videoURLs(in: unescaped).filter { $0.path.contains("/\(videoID)/") }
            if let best = bestVideo(urls) {
                media = [.init(kind: .video, url: best)]
            }
        }
        if media.isEmpty {
            var ids: [String] = []
            if let ogImage, let id = mediaID(ogImage) { ids.append(id) }
            ids += imageURLs(in: unescaped).compactMap(mediaID)
            var seen: Set<String> = []
            media = ids.compactMap { id in
                guard seen.insert(id).inserted else { return nil }
                return URL(string: "https://pbs.twimg.com/media/\(id)?format=jpg&name=large").map {
                    XMediaItem(kind: .image, url: $0)
                }
            }
        }
        return (media, caption.flatMap { $0.isEmpty ? nil : $0 })
    }

    private static func videoThumbID(_ raw: String) -> String? {
        firstMatch(#"amplify_video_thumb/([0-9]+)/"#, in: raw)
    }

    private static func mediaID(_ raw: String) -> String? {
        firstMatch(#"pbs\.twimg\.com/media/([A-Za-z0-9_-]+)"#, in: raw)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    private static func videoURLs(in text: String) -> [URL] {
        matches(#"https://video\.twimg\.com/[^"'\s\\]+"#, in: text).compactMap { raw in
            guard raw.contains(".mp4"), let url = URL(string: raw), url.scheme?.lowercased() == "https" else {
                return nil
            }
            return url
        }
    }

    private static func imageURLs(in text: String) -> [String] {
        matches(#"https://pbs\.twimg\.com/media/[A-Za-z0-9_-]+"#, in: text)
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    private static func bestVideo(_ urls: [URL]) -> URL? {
        func area(_ url: URL) -> Int {
            guard let regex = try? NSRegularExpression(pattern: #"/(\d+)x(\d+)/"#),
                  let match = regex.firstMatch(in: url.path, range: NSRange(url.path.startIndex..., in: url.path)),
                  let width = Range(match.range(at: 1), in: url.path).flatMap({ Int(url.path[$0]) }),
                  let height = Range(match.range(at: 2), in: url.path).flatMap({ Int(url.path[$0]) })
            else { return 0 }
            return width * height
        }
        return urls.max { area($0) < area($1) }
    }
}

enum XPageMediaError: Error, Equatable {
    case unreadable
}
