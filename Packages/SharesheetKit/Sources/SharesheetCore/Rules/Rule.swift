import Foundation

public enum RuleField: String, Codable, Sendable { case type, url, domain, title, note, text, tag }

public enum RuleOperator: String, Codable, Sendable { case `is`, contains }

public struct RuleCondition: Codable, Equatable, Sendable {
    public var field: RuleField
    public var op: RuleOperator
    public var value: String

    public init(field: RuleField, op: RuleOperator, value: String) {
        self.field = field
        self.op = op
        self.value = value
    }
}

/// JSON: `{"addTag":"apple"}` or `{"moveTo":"Sozialversicherung"}`.
public enum RuleAction: Codable, Equatable, Sendable {
    case addTag(String)
    case moveTo(String)
    /// A pattern with `{Datum}` and optionally `{Uhrzeit}`, see `DateExtractor`.
    case setDate(String)

    private enum Key: String, CodingKey { case addTag, moveTo, setDate }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        if let tag = try container.decodeIfPresent(String.self, forKey: .addTag) {
            self = .addTag(tag)
        } else if let collection = try container.decodeIfPresent(String.self, forKey: .moveTo) {
            self = .moveTo(collection)
        } else if let pattern = try container.decodeIfPresent(String.self, forKey: .setDate) {
            self = .setDate(pattern)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown rule action"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        switch self {
        case .addTag(let tag): try container.encode(tag, forKey: .addTag)
        case .moveTo(let collection): try container.encode(collection, forKey: .moveTo)
        case .setDate(let pattern): try container.encode(pattern, forKey: .setDate)
        }
    }
}

/// Whether all conditions of a rule must hold, or at least one.
public enum RuleMatch: String, Codable, Sendable { case all, any }

public struct Rule: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var match: RuleMatch
    public var conditions: [RuleCondition]
    public var actions: [RuleAction]

    public init(
        id: String, name: String, enabled: Bool, match: RuleMatch = .all, conditions: [RuleCondition], actions: [RuleAction]
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.match = match
        self.conditions = conditions
        self.actions = actions
    }

    private enum Key: String, CodingKey { case id, name, enabled, match, conditions, actions }

    /// `match` is optional in the file; files from before it existed mean `all`.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        match = try c.decodeIfPresent(RuleMatch.self, forKey: .match) ?? .all
        conditions = try c.decode([RuleCondition].self, forKey: .conditions)
        actions = try c.decode([RuleAction].self, forKey: .actions)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(enabled, forKey: .enabled)
        if match != .all { try c.encode(match, forKey: .match) }
        try c.encode(conditions, forKey: .conditions)
        try c.encode(actions, forKey: .actions)
    }

    /// At least one condition, no condition without a value, and at least one action that does something.
    /// Anything else would never apply, or (without conditions) apply to every item.
    public var isUsable: Bool {
        !conditions.isEmpty
            && conditions.allSatisfy { !RuleContext.normalized($0.value).isEmpty }
            && actions.contains { action in
                switch action {
                case .addTag(let value), .moveTo(let value): !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                case .setDate(let pattern): DateExtractor.isValid(pattern: pattern)
                }
            }
    }
}

public struct RuleSet: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let empty = RuleSet(version: currentVersion, rules: [])

    public var version: Int
    public var rules: [Rule]

    public init(version: Int = RuleSet.currentVersion, rules: [Rule]) {
        self.version = version
        self.rules = rules
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> RuleSet {
        let set = try JSONDecoder().decode(RuleSet.self, from: data)
        guard set.version == currentVersion else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unsupported rules version \(set.version)"))
        }
        return set
    }
}

public enum RuleLoad: Equatable, Sendable {
    case none
    case rules(RuleSet)
    case invalid(String)
}

public enum RuleFile {
    public static let name = "rules.json"

    /// Reads `<root>/rules.json`, coordinated because the library lives in iCloud.
    public static func load(from root: URL) -> RuleLoad {
        let url = root.appending(path: name)
        guard FileManager.default.fileExists(atPath: url.path) else { return .none }
        var readError: NSError?
        var result = RuleLoad.invalid("The rules file could not be read.")
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &readError) { readURL in
            do {
                result = .rules(try RuleSet.decode(Data(contentsOf: readURL)))
            } catch {
                result = .invalid(error.localizedDescription)
            }
        }
        if let readError { return .invalid(readError.localizedDescription) }
        return result
    }

    /// Writes the rules file, replacing it atomically; coordinated because the library lives in iCloud.
    public static func save(_ set: RuleSet, to root: URL) throws {
        let data = try set.encoded()
        let url = root.appending(path: name)
        var coordinationError: NSError?
        var writeError: (any Error)?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { writeURL in
            do { try data.write(to: writeURL, options: .atomic) } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }
    }

    /// Copies a rules file that cannot be read to `rules.json.broken` (`… 2`, `… 3` when taken). Never deletes.
    @discardableResult
    public static func backUpBroken(in root: URL) throws -> URL {
        let source = root.appending(path: name)
        var target = root.appending(path: name + ".broken")
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = root.appending(path: name + ".broken \(n)")
            n += 1
        }
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }
}
