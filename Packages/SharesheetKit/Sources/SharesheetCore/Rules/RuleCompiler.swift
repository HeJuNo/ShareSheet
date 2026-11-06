import Foundation

/// One field a matching rule defines: read from the text by `pattern` (then calculated on by `op`/`operand`),
/// or calculated from other fields by `formula`.
public struct FieldDefinition: Codable, Equatable, Sendable {
    public var name: String
    public var pattern: String?
    public var formula: String?
    public var op: FieldOperator?
    public var operand: Double?

    public init(name: String, pattern: String? = nil, formula: String? = nil, op: FieldOperator? = nil, operand: Double? = nil) {
        self.name = name
        self.pattern = pattern
        self.formula = formula
        self.op = op
        self.operand = operand
    }
}

public struct RuleOutcome: Equatable, Sendable {
    public var tags: [String]
    public var moveTo: String?
    /// Date patterns of the matching rules, in rule order, without repeats.
    public var datePatterns: [String]
    /// Field definitions of the matching rules, in rule order, without repeats.
    public var fieldDefinitions: [FieldDefinition]
    /// Title templates of the matching rules, in rule order, without repeats.
    public var titleTemplates: [String]

    public init(
        tags: [String], moveTo: String?, datePatterns: [String] = [], fieldDefinitions: [FieldDefinition] = [],
        titleTemplates: [String] = []
    ) {
        self.tags = tags
        self.moveTo = moveTo
        self.datePatterns = datePatterns
        self.fieldDefinitions = fieldDefinitions
        self.titleTemplates = titleTemplates
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

        for rule in set.rules where rule.enabled && rule.isUsable {
            // Values first (conditions, then actions), so a rule's rows can share the action values.
            var conditionCells: [(column: String, expression: String)] = []
            var used: [RuleField: Int] = [:]
            for condition in rule.conditions {
                let n = used[condition.field, default: 0]
                used[condition.field] = n + 1
                let column = "in_\(condition.field.rawValue)_\(n)"
                inputColumns[column] = condition.field.rawValue
                let reference = "rv[\(values.count)]"
                values.append(RuleContext.normalized(condition.value).lowercased())
                let exact = condition.op == .is && condition.field != .tag
                conditionCells.append((column, exact ? "$ == \(reference)" : "contains($, \(reference))"))
            }
            var tagReferences: [String] = []
            var moveReference: String?
            var dateReference: String?
            var fieldReferences: [String] = []
            var titleReference: String?
            for action in rule.actions {
                switch action {
                case .addTag(let tag):
                    let tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !tag.isEmpty {
                        tagReferences.append("rv[\(values.count)]")
                        values.append(tag)
                    }
                case .moveTo(let collection):
                    let collection = collection.trimmingCharacters(in: .whitespacesAndNewlines)
                    if moveReference == nil, !collection.isEmpty {
                        moveReference = "rv[\(values.count)]"
                        values.append(collection)
                    }
                case .setDate(let pattern):
                    if dateReference == nil, DateExtractor.isValid(pattern: pattern) {
                        dateReference = "rv[\(values.count)]"
                        values.append(pattern)
                    }
                case .setField(let name, let pattern, _, let op, let operand):
                    let definition = FieldDefinition(
                        name: name.trimmingCharacters(in: .whitespaces), pattern: pattern, op: op, operand: operand)
                    if action.isUsable {
                        fieldReferences.append("rv[\(values.count)]")
                        values.append(Self.json(definition))
                    }
                case .setComputed(let name, let formula, _):
                    let definition = FieldDefinition(name: name.trimmingCharacters(in: .whitespaces), formula: formula)
                    if action.isUsable {
                        fieldReferences.append("rv[\(values.count)]")
                        values.append(Self.json(definition))
                    }
                case .setTitle(let template):
                    if titleReference == nil, !TitleTemplate.placeholders(in: template).isEmpty {
                        titleReference = "rv[\(values.count)]"
                        values.append(template)
                    }
                }
            }
            var outputs: [String: String] = [:]
            if !tagReferences.isEmpty { outputs["out_addTags"] = "[" + tagReferences.joined(separator: ", ") + "]" }
            if let moveReference { outputs["out_moveTo"] = moveReference }
            if let dateReference { outputs["out_setDate"] = dateReference }
            if !fieldReferences.isEmpty { outputs["out_setField"] = "[" + fieldReferences.joined(separator: ", ") + "]" }
            if let titleReference { outputs["out_setTitle"] = titleReference }

            // "all": one row with every condition; "any": one row per condition.
            let groups = rule.match == .all ? [conditionCells] : conditionCells.map { [$0] }
            for (n, cells) in groups.enumerated() {
                var row = outputs
                row["_id"] = rule.match == .all ? rule.id : "\(rule.id)#\(n)"
                for cell in cells { row[cell.column] = cell.expression }
                rows.append(row)
            }
        }
        guard !rows.isEmpty else { return nil }

        let inputs = inputColumns.keys.sorted().map {
            ["id": $0, "name": $0, "field": inputColumns[$0]!, "type": "expression"]
        }
        let outputs = ["addTags", "moveTo", "setDate", "setField", "setTitle"].map { ["id": "out_\($0)", "name": $0, "field": $0, "type": "expression"] }
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
        var patterns: [String] = []
        var fields: [FieldDefinition] = []
        var titles: [String] = []
        for row in rows {
            for json in (row["setField"] as? [String]) ?? [] {
                if let definition = try? JSONDecoder().decode(FieldDefinition.self, from: Data(json.utf8)),
                    !fields.contains(definition)
                {
                    fields.append(definition)
                }
            }
            if let title = row["setTitle"] as? String, !title.isEmpty, !titles.contains(title) { titles.append(title) }
            for tag in (row["addTags"] as? [String]) ?? [] {
                let tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                if !tag.isEmpty, !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) { tags.append(tag) }
            }
            if let pattern = row["setDate"] as? String, !pattern.isEmpty, !patterns.contains(pattern) { patterns.append(pattern) }
            if move == nil, let target = (row["moveTo"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                !target.isEmpty
            {
                move = target
            }
        }
        return RuleOutcome(tags: tags, moveTo: move, datePatterns: patterns, fieldDefinitions: fields, titleTemplates: titles)
    }

    private static func json(_ definition: FieldDefinition) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: (try? encoder.encode(definition)) ?? Data(), as: UTF8.self)
    }
}
