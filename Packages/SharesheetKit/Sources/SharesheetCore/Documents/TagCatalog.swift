import Foundation

/// Cleans proposed tag names and maps near-duplicates onto existing tags. Pure and deterministic.
public enum TagCatalog {
    private static let maxLength = 40
    private static let maxWords = 3
    private static let suffixes = ["ern", "en", "er", "es", "e", "n", "s"]  // longest first
    private static let minStemLength = 4
    private static let fuzzyMinLength = 7

    /// The existing spelling when `proposed` is a near-duplicate of one of `existing`, else `proposed`
    /// trimmed with inner whitespace collapsed. Nil when unusable: empty, over 40 characters,
    /// more than 3 words, or no letters or digits.
    public static func resolve(_ proposed: String, among existing: [String]) -> String? {
        let words = proposed.split(whereSeparator: { $0.isWhitespace })
        let cleaned = words.joined(separator: " ")
        guard !words.isEmpty, words.count <= maxWords, cleaned.count <= maxLength,
              cleaned.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }

        let proposedKey = key(cleaned)
        for tag in existing where isDuplicate(proposedKey, key(tag)) { return tag }
        return cleaned
    }

    /// True when `tags` holds `tag`, ignoring case.
    public static func contains(_ tags: [String], _ tag: String) -> Bool {
        tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }

    /// True when `tags` already holds `tag`, or a spelling `resolve` treats as the same tag.
    public static func carries(_ tags: [String], _ tag: String) -> Bool {
        if contains(tags, tag) { return true }
        if let resolved = resolve(tag, among: tags), tags.contains(resolved) { return true }
        return false
    }

    private static func key(_ name: String) -> String {
        var s = name.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .replacingOccurrences(of: "ß", with: "ss")
        s.removeAll { $0.isWhitespace || $0 == "-" }
        for suffix in suffixes where s.hasSuffix(suffix) && s.count - suffix.count >= minStemLength {
            s.removeLast(suffix.count)
            break
        }
        return s
    }

    private static func isDuplicate(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        return a.count >= fuzzyMinLength && b.count >= fuzzyMinLength && distance(a, b) <= 1
    }

    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var previous = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(b.count, 1) where !b.isEmpty {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
