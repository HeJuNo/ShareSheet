import Foundation

/// Posts on X, Instagram and Facebook sit behind a login wall when opened directly. Their official oEmbed
/// endpoints serve public posts without an account: the embed markup is rendered and captured instead.
public enum SocialEmbed {
    public enum Platform: String, Sendable {
        case x, instagram, facebook
    }

    /// The fields of an oEmbed response this app uses.
    public struct Response: Decodable, Equatable, Sendable {
        public var html: String
        public var authorName: String?

        public init(html: String, authorName: String? = nil) {
            self.html = html
            self.authorName = authorName
        }

        private enum CodingKeys: String, CodingKey {
            case html
            case authorName = "author_name"
        }
    }

    public static func platform(of url: URL) -> Platform? {
        guard url.isWebPage, var host = url.host()?.lowercased() else { return nil }
        for prefix in ["www.", "m.", "mobile.", "web."] where host.hasPrefix(prefix) {
            host.removeFirst(prefix.count)
        }
        switch host {
        case "x.com", "twitter.com": return url.path().contains("/status/") ? .x : nil
        case "instagram.com": return .instagram
        case "facebook.com", "fb.watch", "fb.com": return .facebook
        default: return nil
        }
    }

    /// The official oEmbed request for a post, nil when `url` is not one of the supported platforms.
    public static func endpoint(for url: URL) -> URL? {
        guard let platform = platform(of: url) else { return nil }
        let base: String
        var query = [URLQueryItem(name: "url", value: url.absoluteString)]
        switch platform {
        case .x:
            base = "https://publish.x.com/oembed"
            query += [URLQueryItem(name: "omit_script", value: "1"), URLQueryItem(name: "dnt", value: "true")]
        case .instagram:
            base = "https://graph.facebook.com/v25.0/instagram_oembed"
        case .facebook:
            base = "https://graph.facebook.com/v25.0/" + (isFacebookVideo(url) ? "oembed_video" : "oembed_post")
        }
        var components = URLComponents(string: base)
        components?.queryItems = query
        return components?.url
    }

    /// Facebook's share links (`/share/…`, what its app hands out) are short links the oEmbed endpoints refuse;
    /// they redirect to the post itself, which is then embedded.
    public static func needsResolving(_ url: URL) -> Bool {
        platform(of: url) == .facebook && url.path().lowercased().hasPrefix("/share/")
    }

    public static func decode(_ data: Data) throws -> Response {
        try JSONDecoder().decode(Response.self, from: data)
    }

    /// A phone-sized page around the embed markup, with the platform's script that turns it into the post.
    public static func page(for response: Response, platform: Platform) -> String {
        let script: String
        switch platform {
        case .x: script = #"<script async src="https://platform.twitter.com/widgets.js" charset="utf-8"></script>"#
        // Instagram's and Facebook's markup bring their own script.
        case .instagram, .facebook: script = ""
        }
        return """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>body { margin: 0; padding: 12px; background: #fff; }</style>
            </head>
            <body>
            \(response.html)
            \(script)
            </body>
            </html>
            """
    }

    /// The post text carried in the embed markup (X sends the full text), nil when there is none.
    public static func text(of response: Response) -> String? {
        guard let start = response.html.range(of: "<p", options: .caseInsensitive),
              let end = response.html.range(of: "</p>", options: .caseInsensitive, range: start.upperBound..<response.html.endIndex)
        else { return nil }
        var paragraph = String(response.html[start.lowerBound..<end.lowerBound])
        paragraph = paragraph.replacingOccurrences(of: "<br ?/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        paragraph = paragraph.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let text = decodeEntities(paragraph).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func isFacebookVideo(_ url: URL) -> Bool {
        let path = url.path().lowercased()
        return url.host()?.lowercased() == "fb.watch" || path.contains("/videos/") || path.hasPrefix("/watch")
            || path.hasPrefix("/reel")
    }

    private static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, character) in [("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"),
                                    ("&mdash;", "—"), ("&nbsp;", " "), ("&amp;", "&")] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        return result
    }
}
