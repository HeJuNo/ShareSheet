import Foundation
import SwiftSoup

public struct FacebookMediaItem: Equatable, Sendable {
    public enum Kind: String, Sendable { case image, video }
    public var kind: Kind
    public var url: URL
    public init(kind: Kind, url: URL) { self.kind = kind; self.url = url }
}

/// Reads a post's photos or its best playable video from Facebook's own page markup.
public enum FacebookPageMedia {
    public static func decode(html: String) throws -> (media: [FacebookMediaItem], caption: String?) {
        let doc = try? SwiftSoup.parse(html)
        let videos = videoURLs(in: html, doc: doc)
        if !videos.isEmpty {
            // A video's cover image is its poster, not a second attachment.
            return (dedupe(videos.map { .init(kind: .video, url: $0) }), caption(doc))
        }
        var images = stringValues(of: "photo_image_url", in: html).compactMap(imageURL)
        if images.isEmpty, let cover = meta(doc, "og:image:secure_url") ?? meta(doc, "og:image") {
            images = [imageURL(cover)].compactMap { $0 }
        }
        return (dedupe(images.map { .init(kind: .image, url: $0) }), caption(doc))
    }

    private static func videoURLs(in html: String, doc: Document?) -> [URL] {
        let high = ["browser_native_hd_url", "playable_url_quality_hd", "hd_src"]
        let low = ["browser_native_sd_url", "playable_url", "sd_src"]
        var urls = high.flatMap { stringValues(of: $0, in: html) }.compactMap(videoURL)
        if urls.isEmpty {
            urls = low.flatMap { stringValues(of: $0, in: html) }.compactMap(videoURL)
        }
        if urls.isEmpty {
            for property in ["og:video:secure_url", "og:video:url"] {
                if let raw = meta(doc, property), let url = videoURL(raw) {
                    urls = [url]
                    break
                }
            }
        }
        return urls
    }

    private static func meta(_ doc: Document?, _ property: String) -> String? {
        guard let doc, let element = try? doc.select("meta[property=\(property)]").first(),
              let content = try? element.attr("content")
        else { return nil }
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func caption(_ doc: Document?) -> String? {
        guard let text = meta(doc, "og:description") else { return nil }
        let generic = ["See posts, photos and more on Facebook.", "Log in to Facebook", "Log into Facebook"]
        return generic.contains(where: text.hasPrefix) ? nil : text
    }

    /// Reads the URLs of a JSON field written as an escaped string, e.g. `"playable_url":"https:\/\/…"`.
    private static func stringValues(of field: String, in html: String, limit: Int = 20) -> [String] {
        let escaped = NSRegularExpression.escapedPattern(for: field)
        guard let regex = try? NSRegularExpression(
            pattern: "\"\(escaped)\"\\s*:\\s*\"((?:\\\\.|[^\"\\\\])*)\"")
        else { return [] }
        let text = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: text.length))
            .prefix(limit)
            .compactMap { unescape(text.substring(with: $0.range(at: 1))) }
    }

    private static func unescape(_ raw: String) -> String {
        guard raw.contains("\\") else { return raw }
        guard let data = ("\"\(raw)\"").data(using: .utf8),
              let text = try? JSONDecoder().decode(String.self, from: data)
        else { return raw.replacingOccurrences(of: "\\/", with: "/") }
        return text
    }

    private static func videoURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), isFacebookCDN(url),
              url.path.lowercased().hasSuffix(".mp4")
        else { return nil }
        return url
    }

    private static func imageURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), isFacebookCDN(url),
              ["jpg", "jpeg", "png", "webp"].contains(url.pathExtension.lowercased())
        else { return nil }
        return url
    }

    private static func isFacebookCDN(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host()?.lowercased() else { return false }
        return host == "fbcdn.net" || host.hasSuffix(".fbcdn.net")
    }

    /// The same photo appears once per rendition; images compare by path, videos keep their signed query.
    private static func dedupe(_ items: [FacebookMediaItem]) -> [FacebookMediaItem] {
        var seen = Set<String>()
        return items.filter { item in
            var key = item.url.absoluteString
            if item.kind == .image, var components = URLComponents(url: item.url, resolvingAgainstBaseURL: false) {
                components.query = nil
                key = components.url?.absoluteString ?? key
            }
            return seen.insert(key).inserted
        }
    }
}
