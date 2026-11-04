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

    private enum Key: String, CodingKey { case addTag, moveTo }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        if let tag = try container.decodeIfPresent(String.self, forKey: .addTag) {
            self = .addTag(tag)
        } else if let collection = try container.decodeIfPresent(String.self, forKey: .moveTo) {
            self = .moveTo(collection)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown rule action"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        switch self {
        case .addTag(let tag): try container.encode(tag, forKey: .addTag)
        case .moveTo(let collection): try container.encode(collection, forKey: .moveTo)
        }
    }
}

public struct Rule: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var conditions: [RuleCondition]
    public var actions: [RuleAction]

    public init(id: String, name: String, enabled: Bool, conditions: [RuleCondition], actions: [RuleAction]) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.conditions = conditions
        self.actions = actions
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
}
