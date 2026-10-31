import Foundation
import SwiftSoup

public enum ArchiveText {
    /// Visible body text of an HTML document, whitespace collapsed to single spaces.
    public static func extract(fromHTML html: String) -> String {
        guard let doc = try? SwiftSoup.parse(html), let body = doc.body() else { return "" }
        _ = try? body.select("script, style, noscript, template").remove()
        let text = (try? body.text()) ?? ""
        return text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
