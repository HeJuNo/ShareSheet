import Foundation
import Testing
@testable import SharesheetCore

@Suite struct RuleTests {
    static let examples = RuleSet(version: 1, rules: [
        Rule(id: "r1", name: "Apple", enabled: true,
             conditions: [RuleCondition(field: .type, op: .is, value: "link"),
                          RuleCondition(field: .url, op: .contains, value: "apple.com")],
             actions: [.addTag("apple")]),
        Rule(id: "r2", name: "SVS", enabled: false,
             conditions: [RuleCondition(field: .text, op: .contains, value: "SVS"),
                          RuleCondition(field: .text, op: .contains, value: "Kontoauszug")],
             actions: [.moveTo("Sozialversicherung"), .addTag("svs")]),
    ])

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "RuleTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func encodeDecodeRoundTripsTheTwoExamples() throws {
        let data = try Self.examples.encoded()
        #expect(try RuleSet.decode(data) == Self.examples)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"addTag\" : \"apple\""))
        #expect(text.contains("\"moveTo\" : \"Sozialversicherung\""))
    }

    @Test func unknownVersionOrBrokenJSONThrows() {
        #expect(throws: (any Error).self) { try RuleSet.decode(Data(#"{"version":2,"rules":[]}"#.utf8)) }
        #expect(throws: (any Error).self) { try RuleSet.decode(Data("nope".utf8)) }
        #expect(throws: (any Error).self) { try RuleSet.decode(Data(#"{"version":1,"rules":[{"id":"a","name":"x","enabled":true,"conditions":[],"actions":[{"unknown":"y"}]}]}"#.utf8)) }
    }

    @Test func loadReturnsNoneWhenMissing() throws {
        #expect(RuleFile.load(from: try tempDir()) == .none)
    }

    @Test func loadReturnsRulesWhenValid() throws {
        let root = try tempDir()
        try Self.examples.encoded().write(to: root.appending(path: RuleFile.name))
        #expect(RuleFile.load(from: root) == .rules(Self.examples))
    }

    @Test func loadReturnsInvalidWithAMessageWhenBroken() throws {
        let root = try tempDir()
        try Data("{ not json".utf8).write(to: root.appending(path: RuleFile.name))
        guard case .invalid(let message) = RuleFile.load(from: root) else { Issue.record("expected .invalid"); return }
        #expect(!message.isEmpty)
    }
}
