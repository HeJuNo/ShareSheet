import Foundation

/// Reads one typed value from a document text by a pattern with exactly one placeholder: `{Zahl}`, `{Datum}`
/// or `{Text}`. The rest of the pattern must match as written, except that spacing and line breaks may differ
/// and case does not matter. The first place that fits wins; an unreadable value gives nil, never a guess.
public enum FieldExtractor {
    private enum Kind: String { case number = "zahl", date = "datum", text = "text" }

    private static let placeholder = try! NSRegularExpression(pattern: #"\{(\w+)\}"#)

    private static func kinds(in pattern: String) -> [Kind] {
        let range = NSRange(pattern.startIndex..., in: pattern)
        return placeholder.matches(in: pattern, range: range).compactMap {
            Kind(rawValue: String(pattern[Range($0.range(at: 1), in: pattern)!]).lowercased())
        }
    }

    public static func isValid(pattern: String) -> Bool { kinds(in: pattern).count == 1 }

    public static func value(in text: String, pattern: String, timeZone: TimeZone = .current) -> FieldValue? {
        guard isValid(pattern: pattern), let kind = kinds(in: pattern).first else { return nil }
        if kind == .date { return DateExtractor.date(in: text, pattern: pattern, timeZone: timeZone).map(FieldValue.date) }

        // The pattern has exactly one placeholder: literal text before it, the value, literal text after it.
        let range = NSRange(pattern.startIndex..., in: pattern)
        guard let match = placeholder.firstMatch(in: pattern, range: range), let whole = Range(match.range, in: pattern)
        else { return nil }
        let expression = DateExtractor.literalExpression(String(pattern[..<whole.lowerBound]))
            + (kind == .number ? #"(-?\d[\d.,]*)"# : #"([^\n\r]+)"#)
            + DateExtractor.literalExpression(String(pattern[whole.upperBound...]))
        guard let regex = try? NSRegularExpression(pattern: expression, options: [.caseInsensitive]),
            let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let valueRange = Range(found.range(at: 1), in: text)
        else { return nil }
        let raw = String(text[valueRange])
        switch kind {
        case .number: return number(raw).map(FieldValue.number)
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
