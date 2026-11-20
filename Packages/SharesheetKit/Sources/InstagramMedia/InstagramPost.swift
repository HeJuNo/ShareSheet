import Foundation
import SharesheetCore

public enum InstagramPost {
    public static func shortcode(in url: URL) -> String? { post(in: url)?.shortcode }

    public static func embedURL(for url: URL) -> URL? {
        guard let post = post(in: url) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.instagram.com"
        components.path = "/\(post.kind)/\(post.shortcode)/embed/captioned/"
        return components.url
    }

    /// `/p/`, `/reel/`, `/reels/` und `/tv/` auf instagram.com; Host-Präfixe wie `www.`/`m.` zählen nicht.
    private static func post(in url: URL) -> (kind: String, shortcode: String)? {
        guard url.isWebPage, var host = url.host()?.lowercased() else { return nil }
        for prefix in ["www.", "m.", "mobile.", "web."] where host.hasPrefix(prefix) { host.removeFirst(prefix.count) }
        guard host == "instagram.com" else { return nil }
        let parts = url.path().split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        let kind = parts[0] == "reels" ? "reel" : parts[0]
        guard ["p", "reel", "tv"].contains(kind) else { return nil }
        let code = parts[1]
        guard !code.isEmpty,
              code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
        else { return nil }
        return (kind, code)
    }
}

extension InstagramPost {
    public struct Media: Equatable, Sendable {
        public enum Kind: String, Sendable { case image, video }
        public var kind: Kind
        public var url: URL
        public init(kind: Kind, url: URL) { self.kind = kind; self.url = url }
    }

    public struct Post: Equatable, Sendable {
        public var media: [Media]
        public var caption: String?
        public var author: String?
        public init(media: [Media], caption: String? = nil, author: String? = nil) {
            self.media = media; self.caption = caption; self.author = author
        }
    }
}
