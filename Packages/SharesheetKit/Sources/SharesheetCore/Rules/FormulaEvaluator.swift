import Foundation

/// Small arithmetic over numbers and `{Field}` references: `+ - * /`, parentheses, unary minus.
public enum FormulaEvaluator {
    /// Field names in order of first use; nil when the formula is not valid.
    public static func references(in formula: String) -> [String]? {
        var parser = Parser(formula, fields: nil)
        guard parser.parse() != nil else { return nil }
        return parser.used
    }

    /// nil on a syntax error, a missing field, a division by zero or a non-finite result.
    public static func evaluate(_ formula: String, fields: [String: Double]) -> Double? {
        var parser = Parser(formula, fields: fields)
        guard let value = parser.parse(), value.isFinite else { return nil }
        return value
    }

    private struct Parser {
        let chars: [Character]
        let fields: [String: Double]?   // nil: only check syntax and collect references
        var pos = 0
        var used: [String] = []

        init(_ text: String, fields: [String: Double]?) { chars = Array(text); self.fields = fields }

        mutating func parse() -> Double? {
            guard let value = expression(), skipSpace() == nil else { return nil }
            return value
        }

        @discardableResult
        mutating func skipSpace() -> Character? {
            while pos < chars.count, chars[pos].isWhitespace { pos += 1 }
            return pos < chars.count ? chars[pos] : nil
        }

        mutating func expression() -> Double? {
            guard var left = term() else { return nil }
            while let c = skipSpace(), c == "+" || c == "-" {
                pos += 1
                guard let right = term() else { return nil }
                left = c == "+" ? left + right : left - right
            }
            return left
        }

        mutating func term() -> Double? {
            guard var left = factor() else { return nil }
            while let c = skipSpace(), c == "*" || c == "/" {
                pos += 1
                guard let right = factor() else { return nil }
                if c == "*" { left *= right } else {
                    guard right != 0 || fields == nil else { return nil }
                    left = right == 0 ? 0 : left / right
                }
            }
            return left
        }

        mutating func factor() -> Double? {
            guard let c = skipSpace() else { return nil }
            if c == "-" { pos += 1; return factor().map { -$0 } }
            if c == "(" {
                pos += 1
                guard let value = expression(), skipSpace() == ")" else { return nil }
                pos += 1
                return value
            }
            if c == "{" {
                guard let end = chars[pos...].firstIndex(of: "}") else { return nil }
                let name = String(chars[(pos + 1)..<end])
                guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                pos = end + 1
                if !used.contains(name) { used.append(name) }
                guard let fields else { return 0 }
                return fields[name]
            }
            let start = pos
            while pos < chars.count, chars[pos].isASCII, chars[pos].isNumber || chars[pos] == "." { pos += 1 }
            return Double(String(chars[start..<pos]))
        }
    }
}
