import Foundation

/// Reads a date (and time) from a document text by a pattern with placeholders:
/// `Ihr Einkauf am {Datum} um {Uhrzeit} Uhr`. `{Datum}` is day.month.year (`02.11.2026`, `2.11.26`),
/// `{Uhrzeit}` is hour:minute or hour.minute with optional seconds. The other text must match as written,
/// except that spacing and line breaks may differ and case does not matter.
public enum DateExtractor {
    // Six groups: year/month/day (`2026/02/22`, `2026-02-22`) or day/month/year (`02.11.2026`, `2.11.26`).
    private static let datum = #"(?<!\d)(?:(\d{4})[/-](\d{1,2})[/-](\d{1,2})|(\d{1,2})\.(\d{1,2})\.(\d{4}|\d{2}))(?!\d)"#
    private static let uhrzeit = #"(?<!\d)(\d{1,2})[:.](\d{2})(?::(\d{2}))?(?!\d)"#

    private enum Placeholder { case date, time }
    private enum Part {
        case literal(String)
        case placeholder(Placeholder)
    }

    /// Exactly one `{Datum}` and at most one `{Uhrzeit}`.
    public static func isValid(pattern: String) -> Bool {
        let placeholders = parts(of: pattern).compactMap { part -> Placeholder? in
            if case .placeholder(let placeholder) = part { placeholder } else { nil }
        }
        return placeholders.filter { $0 == .date }.count == 1 && placeholders.filter { $0 == .time }.count <= 1
    }

    /// The date of the first place in `text` that fits `pattern`; nil when there is none, the pattern is
    /// invalid, or the first place holds an impossible date (31.02., month 13, hour 25).
    public static func date(in text: String, pattern: String, timeZone: TimeZone = .current) -> Date? {
        guard isValid(pattern: pattern) else { return nil }
        var order: [Placeholder] = []
        var expression = ""
        for part in parts(of: pattern) {
            switch part {
            case .literal(let literal):
                expression += literalExpression(literal)
            case .placeholder(let placeholder):
                order.append(placeholder)
                expression += placeholder == .date ? datum : uhrzeit
            }
        }
        guard let regex = try? NSRegularExpression(pattern: expression, options: [.caseInsensitive]),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }

        func number(_ group: Int) -> Int? {
            let range = match.range(at: group)
            return range.location == NSNotFound ? nil : Int(text[Range(range, in: text)!])
        }
        var components = DateComponents(hour: 0, minute: 0, second: 0)
        var group = 1
        for placeholder in order {
            switch placeholder {
            case .date:
                var year: Int, month: Int, day: Int
                if let y = number(group), let m = number(group + 1), let d = number(group + 2) {
                    (year, month, day) = (y, m, d)
                } else if let d = number(group + 3), let m = number(group + 4), let y = number(group + 5) {
                    (year, month, day) = (y, m, d)
                } else {
                    return nil
                }
                if year < 100 { year += 2000 }
                components.year = year
                components.month = month
                components.day = day
                group += 6
            case .time:
                guard let hour = number(group), let minute = number(group + 1) else { return nil }
                components.hour = hour
                components.minute = minute
                components.second = number(group + 2) ?? 0
                group += 3
            }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // Rejects what the calendar would roll over (31.02. becomes 3.3.).
        guard let date = calendar.date(from: components),
            calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date) == DateComponents(
                year: components.year, month: components.month, day: components.day,
                hour: components.hour, minute: components.minute, second: components.second)
        else { return nil }
        return date
    }

    private static func parts(of pattern: String) -> [Part] {
        var result: [Part] = []
        var rest = Substring(pattern)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            let name = rest[rest.index(after: open)..<close].lowercased()
            guard name == "datum" || name == "uhrzeit" else {
                // Not a placeholder: keep the brace as text.
                result.append(.literal(String(rest[...open])))
                rest = rest[rest.index(after: open)...]
                continue
            }
            if open > rest.startIndex { result.append(.literal(String(rest[..<open]))) }
            result.append(.placeholder(name == "datum" ? .date : .time))
            rest = rest[rest.index(after: close)...]
        }
        if !rest.isEmpty { result.append(.literal(String(rest))) }
        return result
    }

    /// Text as written, with any run of spacing matching any run of spacing in the document.
    static func literalExpression(_ literal: String) -> String {
        var expression = ""
        var inSpace = false
        for character in literal {
            if character.isWhitespace {
                if !inSpace { expression += #"\s+"# }
                inSpace = true
            } else {
                inSpace = false
                expression += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        return expression
    }
}
