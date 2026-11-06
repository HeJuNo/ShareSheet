import Foundation

/// Reads one typed value from a document text by a pattern with exactly one placeholder: `{Zahl}`, `{Datum}`
/// or `{Text}`; `{Zahl|#.###,##}` names the number format (here German: `.` groups thousands, `,` is the decimal
/// separator; `{Zahl|#,###.##}` is the English one). The rest of the pattern must match as written, except that spacing and line breaks may differ
/// and case does not matter. The first place that fits wins; an unreadable value gives nil, never a guess.
public enum FieldExtractor {
    private enum Kind: String { case number = "zahl", date = "datum", text = "text" }

    private static let placeholder = try! NSRegularExpression(pattern: #"\{(\w+)(?:\|([^{}]*))?\}"#)

    /// Placeholders with a known kind; a placeholder with an unusable mask counts as none, so the pattern is invalid.
    private static func kinds(in pattern: String) -> [Kind] {
        let range = NSRange(pattern.startIndex..., in: pattern)
        return placeholder.matches(in: pattern, range: range).compactMap { match in
            guard let kind = Kind(rawValue: String(pattern[Range(match.range(at: 1), in: pattern)!]).lowercased()) else { return nil }
            if let maskRange = Range(match.range(at: 2), in: pattern) {
                guard kind == .number, NumberFormat(mask: String(pattern[maskRange])) != nil else { return nil }
            }
            return kind
        }
    }

    public static func isValid(pattern: String) -> Bool { kinds(in: pattern).count == 1 }

    /// Whether the single placeholder is a number (with or without a format).
    public static func isNumber(pattern: String) -> Bool { isValid(pattern: pattern) && kinds(in: pattern).first == .number }

    /// Separators of a mask such as `#.###,##`: the last of `.`/`,` is the decimal separator when both occur; a lone
    /// separator groups thousands when exactly three digit places follow it (or when it repeats), else it is decimal.
    struct NumberFormat {
        var grouping: Character?
        var decimal: Character?

        init?(mask: String) {
            guard !mask.isEmpty, mask.allSatisfy({ "#0.,".contains($0) }), mask.contains(where: { $0 == "#" || $0 == "0" })
            else { return nil }
            let separators = mask.filter { $0 == "." || $0 == "," }
            guard let last = separators.last, let lastIndex = mask.lastIndex(of: last) else { return }  // integers only
            let after = mask[mask.index(after: lastIndex)...]
            guard after.count > 0, after.allSatisfy({ $0 == "#" || $0 == "0" }) else { return nil }
            if Set(separators).count == 2 {
                decimal = last
                grouping = last == "." ? "," : "."
            } else if separators.count > 1 || after.count == 3 {
                grouping = last
            } else {
                decimal = last
            }
        }

        /// The number in `raw` under this format, nil when its separators do not fit it.
        func value(_ raw: String) -> Double? {
            var token = raw
            while let last = token.last, last == "." || last == "," { token.removeLast() }
            var integer = Substring(token), fraction = Substring("")
            if let decimal, let split = token.firstIndex(of: decimal) {
                integer = token[..<split]
                fraction = token[token.index(after: split)...]
            }
            if let grouping {
                let groups = integer.split(separator: grouping, omittingEmptySubsequences: false)
                guard groups.dropFirst().allSatisfy({ $0.count == 3 }), let head = groups.first, (1...3).contains(head.count) || groups.count == 1
                else { return nil }
                integer = Substring(groups.joined())
            }
            let negative = integer.hasPrefix("-")
            let digits = negative ? integer.dropFirst() : integer
            guard !digits.isEmpty, digits.allSatisfy(\.isASCIIDigit), fraction.allSatisfy(\.isASCIIDigit) else { return nil }
            return Double("\(negative ? "-" : "")\(digits)\(fraction.isEmpty ? "" : "." + fraction)")
        }
    }

    public static func value(in text: String, pattern: String, timeZone: TimeZone = .current) -> FieldValue? {
        guard isValid(pattern: pattern), let kind = kinds(in: pattern).first else { return nil }
        if kind == .date { return DateExtractor.date(in: text, pattern: pattern, timeZone: timeZone).map(FieldValue.date) }

        // The pattern has exactly one placeholder: literal text before it, the value, literal text after it.
        let range = NSRange(pattern.startIndex..., in: pattern)
        guard let match = placeholder.firstMatch(in: pattern, range: range), let whole = Range(match.range, in: pattern)
        else { return nil }
        let format = Range(match.range(at: 2), in: pattern).flatMap { NumberFormat(mask: String(pattern[$0])) }
        let expression = DateExtractor.literalExpression(String(pattern[..<whole.lowerBound]))
            + (kind == .number ? #"(-?\d[\d.,]*)"# : #"([^\n\r]+)"#)
            + DateExtractor.literalExpression(String(pattern[whole.upperBound...]))
        guard let regex = try? NSRegularExpression(pattern: expression, options: [.caseInsensitive]),
            let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let valueRange = Range(found.range(at: 1), in: text)
        else { return nil }
        let raw = String(text[valueRange])
        switch kind {
        case .number: return (format?.value(raw) ?? (format == nil ? number(raw) : nil)).map(FieldValue.number)
        case .text:
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : .text(trimmed)
        case .date: return nil
        }
    }

    /// `4.77`, `4,77`, `1.234,56`. The last `.` or `,` is the decimal separator unless exactly three digits
    /// follow it (`1.234` could be a thousand or a decimal: not guessed); earlier separators are thousands.
    static func number(_ raw: String) -> Double? {
        var token = raw
        while let last = token.last, last == "." || last == "," { token.removeLast() }
        guard let separator = token.lastIndex(where: { $0 == "." || $0 == "," }) else { return Double(token) }
        let decimals = token[token.index(after: separator)...]
        guard decimals.count != 3 else { return nil }
        let integer = token[..<separator].filter { $0 != "." && $0 != "," }
        return Double("\(integer).\(decimals)")
    }
}

/// `Tesla {Rechnungsdatum}`: field names in braces, filled from an item's fields.
public enum TitleTemplate {
    private static let placeholder = try! NSRegularExpression(pattern: #"\{([^{}]+)\}"#)

    public static func placeholders(in template: String) -> [String] {
        placeholder.matches(in: template, range: NSRange(template.startIndex..., in: template)).map {
            String(template[Range($0.range(at: 1), in: template)!])
        }
    }

    /// Nil when the template has no placeholder, a field is missing, or the result is empty.
    public static func fill(_ template: String, fields: [String: FieldValue]) -> String? {
        guard !placeholders(in: template).isEmpty else { return nil }
        var result = template
        for match in placeholder.matches(in: template, range: NSRange(template.startIndex..., in: template)).reversed() {
            let name = String(template[Range(match.range(at: 1), in: template)!])
            guard let value = fields[name] else { return nil }
            result.replaceSubrange(Range(match.range, in: result)!, with: display(value))
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func display(_ value: FieldValue) -> String {
        switch value {
        case .number(let number): return number == number.rounded() && abs(number) < 1e15 ? String(Int64(number)) : "\(number)"
        case .text(let text): return text
        case .date(let date):
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date)
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
