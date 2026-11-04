import Foundation

public struct RuleOutcome: Equatable, Sendable {
    public var tags: [String]
    public var moveTo: String?

    public init(tags: [String], moveTo: String?) {
        self.tags = tags
        self.moveTo = moveTo
    }
}

/// A rule set as a ZEN decision (JDM JSON) plus the values its cells refer to. User values never appear in
/// the expressions: cells only index the list `rv`, which travels in the evaluation context.
public struct CompiledRules: Equatable, Sendable {
    public var decision: Data
    public var values: [String]
}

public enum RuleContext {
    public static let maxTextCharacters = 6_000

    /// Runs of whitespace (including line breaks, as in PDF text) become one space, so a phrase matches across them.
    public static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The evaluation input: lowercased fields of the item, its `text`, and the compiled `values` as `rv`.
    public static func json(for item: Item, text: String, values: [String]) -> Data {
        var domain = item.url?.host()?.lowercased() ?? ""
        if domain.hasPrefix("www.") { domain.removeFirst(4) }
        let context: [String: Any] = [
            "type": item.type.rawValue.lowercased(),
            "url": item.url?.absoluteString.lowercased() ?? "",
            "domain": domain,
            "title": normalized(item.title).lowercased(),
            "note": normalized(item.note).lowercased(),
            "text": String(normalized(text).lowercased().prefix(maxTextCharacters)),
            "tag": item.tags.map { $0.lowercased() },
            "rv": values,
        ]
        return (try? JSONSerialization.data(withJSONObject: context)) ?? Data("{}".utf8)
    }
}

public enum RuleCompiler {
    /// Nil when no enabled, valid rule is left. A rule is valid with at least one condition, no empty condition
    /// value and at least one usable action; a row without conditions would match every item.
    public static func compile(_ set: RuleSet) -> CompiledRules? {
        var values: [String] = []
        var inputColumns: [String: String] = [:]  // column id -> context field
        var rows: [[String: String]] = []

        for rule in set.rules where rule.enabled {
            let conditions = rule.conditions.map { ($0, RuleContext.normalized($0.value)) }
            guard !conditions.isEmpty, conditions.allSatisfy({ !$0.1.isEmpty }) else { continue }
            var tagValues: [String] = []
            var move: String?
            for action in rule.actions {
                switch action {
                case .addTag(let tag):
                    let tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !tag.isEmpty { tagValues.append(tag) }
                case .moveTo(let collection):
                    let collection = collection.trimmingCharacters(in: .whitespacesAndNewlines)
                    if move == nil, !collection.isEmpty { move = collection }
                }
            }
            guard !tagValues.isEmpty || move != nil else { continue }

            var row: [String: String] = ["_id": rule.id]
            var used: [RuleField: Int] = [:]
            for (condition, value) in conditions {
                let n = used[condition.field, default: 0]
                used[condition.field] = n + 1
                let column = "in_\(condition.field.rawValue)_\(n)"
                inputColumns[column] = condition.field.rawValue
                let reference = "rv[\(values.count)]"
                values.append(value.lowercased())
                let exact = condition.op == .is && condition.field != .tag
                row[column] = exact ? "$ == \(reference)" : "contains($, \(reference))"
            }
            if !tagValues.isEmpty {
                let references = tagValues.map { tag -> String in
                    values.append(tag)
                    return "rv[\(values.count - 1)]"
                }
                row["out_addTags"] = "[" + references.joined(separator: ", ") + "]"
            }
            if let move {
                row["out_moveTo"] = "rv[\(values.count)]"
                values.append(move)
            }
            rows.append(row)
        }
        guard !rows.isEmpty else { return nil }

        let inputs = inputColumns.keys.sorted().map {
            ["id": $0, "name": $0, "field": inputColumns[$0]!, "type": "expression"]
        }
        let outputs = ["addTags", "moveTo"].map { ["id": "out_\($0)", "name": $0, "field": $0, "type": "expression"] }
        let graph: [String: Any] = [
            "nodes": [
                ["id": "input", "type": "inputNode", "name": "Request", "position": ["x": 0, "y": 0]],
                ["id": "table", "type": "decisionTableNode", "name": "Rules", "position": ["x": 200, "y": 0],
                 "content": ["hitPolicy": "collect", "inputs": inputs, "outputs": outputs, "rules": rows]],
                ["id": "output", "type": "outputNode", "name": "Response", "position": ["x": 400, "y": 0]],
            ],
            "edges": [
                ["id": "e1", "sourceId": "input", "type": "edge", "targetId": "table"],
                ["id": "e2", "sourceId": "table", "type": "edge", "targetId": "output"],
            ],
        ]
        guard let decision = try? JSONSerialization.data(withJSONObject: graph, options: [.sortedKeys]) else { return nil }
        return CompiledRules(decision: decision, values: values)
    }

    /// Reads a `collect` result: an array with one object per matching rule. Broken input gives an empty outcome.
    public static func outcome(fromResult data: Data) -> RuleOutcome {
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return RuleOutcome(tags: [], moveTo: nil)
        }
        var tags: [String] = []
        var move: String?
        for row in rows {
            for tag in (row["addTags"] as? [String]) ?? [] {
                let tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                if !tag.isEmpty, !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) { tags.append(tag) }
            }
            if move == nil, let target = (row["moveTo"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                !target.isEmpty
            {
                move = target
            }
        }
        return RuleOutcome(tags: tags, moveTo: move)
    }
}
