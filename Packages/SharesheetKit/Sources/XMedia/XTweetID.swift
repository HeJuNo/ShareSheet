import Foundation
import SharesheetCore

/// The numeric status id of an X tweet link.
public enum XTweetID {
    public static func string(from url: URL) -> String? {
        guard url.isWebPage, var host = url.host()?.lowercased() else { return nil }
        for prefix in ["www.", "mobile.", "m."] where host.hasPrefix(prefix) { host.removeFirst(prefix.count) }
        guard host == "x.com" || host == "twitter.com" else { return nil }
        let parts = url.path().split(separator: "/").map(String.init)
        guard let status = parts.firstIndex(of: "status"), parts.indices.contains(status + 1) else { return nil }
        let id = parts[status + 1]
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return id
    }
}
