import Foundation

/// Builds file names that are safe on the iCloud Drive file system.
public enum FileNamer {
    private static let reserved: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]
    private static let trimSet = CharacterSet(charactersIn: " .-")

    /// Stems stay under this many UTF-8 bytes, leaving room for a counter and an extension in the
    /// file system's 255-byte name limit.
    static let maxStemBytes = 200
    static let maxExtensionBytes = 32

    /// Turns a title into a single safe file-name stem of at most `maxLength` characters and `maxStemBytes`
    /// UTF-8 bytes, cut on a character boundary. Falls back to `Untitled`.
    public static func sanitize(_ title: String, maxLength: Int = 80) -> String {
        var mapped = ""
        for character in title {
            if character.isWhitespace {
                mapped.append(" ")
            } else if reserved.contains(character)
                        || character.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
                mapped.append("-")
            } else {
                mapped.append(character)
            }
        }
        let collapsed = mapped.split(separator: " ").joined(separator: " ")
        let truncated = String(collapsed.trimmingCharacters(in: trimSet).prefix(maxLength))
        let result = prefix(truncated.trimmingCharacters(in: trimSet), maxBytes: maxStemBytes)
            .trimmingCharacters(in: trimSet)
        return result.isEmpty ? "Untitled" : result
    }

    /// `base.ext`, or `base 2.ext`, `base 3.ext`, ... when the name is taken (case-insensitively).
    public static func uniqueName(base: String, ext: String, existing: Set<String>) -> String {
        firstAvailable(stem: base, ext: ext, separator: " ", existing: existing)
    }

    /// `slug-yyyy-MM-dd.ext` with the slug from `sanitize`, lowercased with spaces as dashes and
    /// the date in UTC. Collisions get `-2`, `-3`, ... before the extension.
    public static func attachmentName(base: String, date: Date, ext: String, existing: Set<String>) -> String {
        let slug = sanitize(base).lowercased().replacingOccurrences(of: " ", with: "-")
        return firstAvailable(stem: "\(slug)-\(utcDay(date))", ext: ext, separator: "-", existing: existing)
    }

    private static func firstAvailable(stem: String, ext: String, separator: String, existing: Set<String>) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        var candidate = name(stem: stem, ext: ext)
        var counter = 2
        while taken.contains(candidate.lowercased()) {
            candidate = name(stem: "\(stem)\(separator)\(counter)", ext: ext)
            counter += 1
        }
        return candidate
    }

    private static func name(stem: String, ext: String) -> String {
        let ext = prefix(ext, maxBytes: maxExtensionBytes)
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }

    /// The longest prefix of whole characters within `maxBytes` UTF-8 bytes.
    private static func prefix(_ text: String, maxBytes: Int) -> String {
        var result = ""
        var bytes = 0
        for character in text {
            let size = character.utf8.count
            guard bytes + size <= maxBytes else { break }
            result.append(character)
            bytes += size
        }
        return result
    }

    private static func utcDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04ld-%02ld-%02ld", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
