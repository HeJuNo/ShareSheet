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

    @Test func matchAnyIsWrittenAndAFileWithoutMatchMeansAll() throws {
        let any = Rule(id: "a", name: "a", enabled: true, match: .any,
                       conditions: [RuleCondition(field: .url, op: .contains, value: "x")], actions: [.addTag("t")])
        let data = try RuleSet(rules: [any]).encoded()
        #expect(String(decoding: data, as: UTF8.self).contains("\"match\" : \"any\""))
        #expect(try RuleSet.decode(data).rules[0].match == .any)

        let stage1 = try RuleSet.decode(try Self.examples.encoded())
        #expect(stage1.rules.allSatisfy { $0.match == .all })
        #expect(!String(decoding: try Self.examples.encoded(), as: UTF8.self).contains("match"))
    }

    @Test func isUsableNeedsConditionsValuesAndAnAction() {
        let ok = RuleCondition(field: .url, op: .contains, value: "x")
        func rule(_ c: [RuleCondition], _ a: [RuleAction]) -> Rule { Rule(id: "r", name: "r", enabled: true, conditions: c, actions: a) }
        #expect(rule([ok], [.addTag("t")]).isUsable)
        #expect(!rule([], [.addTag("t")]).isUsable)
        #expect(!rule([ok, RuleCondition(field: .url, op: .contains, value: " \n ")], [.addTag("t")]).isUsable)
        #expect(!rule([ok], []).isUsable)
        #expect(!rule([ok], [.addTag("  "), .moveTo("")]).isUsable)
    }

    @Test func saveThenLoadRoundTripsAndBackupsAreNumbered() throws {
        let root = try tempDir()
        try Self.examples.encoded().write(to: root.appending(path: RuleFile.name))
        let changed = RuleSet(rules: [Self.examples.rules[0]])
        try RuleFile.save(changed, to: root)
        #expect(RuleFile.load(from: root) == .rules(changed))

        let first = try RuleFile.backUpBroken(in: root)
        let second = try RuleFile.backUpBroken(in: root)
        #expect(first.lastPathComponent == "rules.json.broken")
        #expect(second.lastPathComponent == "rules.json.broken 2")
        #expect(FileManager.default.fileExists(atPath: root.appending(path: RuleFile.name).path))
    }

    @Test func setDateIsAnActionOnlyWithAUsablePattern() throws {
        let cond = RuleCondition(field: .text, op: .contains, value: "Einkauf")
        func rule(_ actions: [RuleAction]) -> Rule { Rule(id: "r", name: "r", enabled: true, conditions: [cond], actions: actions) }
        let good = rule([.setDate("Ihr Einkauf am {Datum} um {Uhrzeit} Uhr")])
        #expect(good.isUsable)
        #expect(!rule([.setDate("Ihr Einkauf")]).isUsable)
        #expect(rule([.setDate("kaputt"), .addTag("t")]).isUsable)
        let data = try RuleSet(rules: [good]).encoded()
        #expect(String(decoding: data, as: UTF8.self).contains("\"setDate\" : \"Ihr Einkauf am {Datum} um {Uhrzeit} Uhr\""))
        #expect(try RuleSet.decode(data).rules == [good])
    }
}

@Suite struct RuleFieldActionTests {
    private let cond = RuleCondition(field: .text, op: .contains, value: "Rechnung")
    private func rule(_ actions: [RuleAction]) -> Rule { Rule(id: "r", name: "r", enabled: true, conditions: [cond], actions: actions) }

    @Test func setFieldNeedsANameAndExactlyOnePlaceholder() throws {
        let good = rule([.setField(name: "Gesamtbetrag", pattern: "Gesamtbetrag (EUR) {Zahl}")])
        #expect(good.isUsable)
        #expect(!rule([.setField(name: " ", pattern: "x {Zahl}")]).isUsable)
        #expect(!rule([.setField(name: "A\nB", pattern: "x {Zahl}")]).isUsable)
        #expect(!rule([.setField(name: "A", pattern: "x")]).isUsable)
        #expect(!rule([.setField(name: "A", pattern: "{Zahl} {Text}")]).isUsable)
        let data = try RuleSet(rules: [good]).encoded()
        #expect(try RuleSet.decode(data).rules == [good])
        #expect(String(decoding: data, as: UTF8.self).contains("\"setField\""))
    }

    @Test func setTitleNeedsAPlaceholder() throws {
        let good = rule([.setTitle("Tesla {Rechnungsdatum}")])
        #expect(good.isUsable)
        #expect(!rule([.setTitle("Tesla")]).isUsable)
        #expect(try RuleSet.decode(RuleSet(rules: [good]).encoded()).rules == [good])
    }
}

@Suite struct RuleAggregateAndComputeTests {
    private let cond = RuleCondition(field: .text, op: .contains, value: "Rechnung")
    private func rule(_ actions: [RuleAction], enabled: Bool = true) -> Rule {
        Rule(id: "r", name: "r", enabled: enabled, conditions: [cond], actions: actions)
    }

    @Test func newFieldSettingsRoundTripAndOldFilesStillLoad() throws {
        let all = rule([
            .setField(name: "A", pattern: "x {Zahl}", aggregate: .average, op: .multiply, operand: 1.19),
            .setComputed(name: "B", formula: "{A} + 1", aggregate: .max),
        ])
        #expect(try RuleSet.decode(RuleSet(rules: [all]).encoded()).rules == [all])
        let old = Data(#"{"version":1,"rules":[{"id":"r","name":"r","enabled":true,"conditions":[{"field":"text","op":"contains","value":"x"}],"actions":[{"setField":{"name":"A","pattern":"x {Zahl}"}}]}]}"#.utf8)
        #expect(try RuleSet.decode(old).rules[0].actions == [.setField(name: "A", pattern: "x {Zahl}")])
        let plain = String(decoding: try RuleSet(rules: [rule([.setField(name: "A", pattern: "x {Zahl}")])]).encoded(), as: UTF8.self)
        #expect(!plain.contains("aggregate") && !plain.contains("operand"))
    }

    @Test func operationsNeedBothPartsANumberPatternAndNoDivisionByZero() {
        #expect(rule([.setField(name: "A", pattern: "x {Zahl}", op: .multiply, operand: 2)]).isUsable)
        #expect(!rule([.setField(name: "A", pattern: "x {Zahl}", op: .multiply)]).isUsable)
        #expect(!rule([.setField(name: "A", pattern: "x {Zahl}", operand: 2)]).isUsable)
        #expect(!rule([.setField(name: "A", pattern: "x {Text}", op: .add, operand: 2)]).isUsable)
        #expect(!rule([.setField(name: "A", pattern: "x {Zahl}", op: .divide, operand: 0)]).isUsable)
    }

    @Test func computedFieldsNeedANameAndAFormulaWithAReference() {
        #expect(rule([.setComputed(name: "Brutto", formula: "{Netto} + {MwSt}")]).isUsable)
        #expect(!rule([.setComputed(name: "Brutto", formula: "1 + 2")]).isUsable)
        #expect(!rule([.setComputed(name: "Brutto", formula: "{Netto} +")]).isUsable)
        #expect(!rule([.setComputed(name: " ", formula: "{Netto}")]).isUsable)
    }

    @Test func theFirstUsableEnabledActionDecidesTheAggregateOfAName() {
        let set = RuleSet(rules: [
            rule([.setField(name: "Off", pattern: "x {Zahl}", aggregate: .min)], enabled: false),
            rule([.setField(name: "A", pattern: "kaputt", aggregate: .min), .setField(name: "A", pattern: "x {Zahl}", aggregate: .max)]),
            rule([.setField(name: "A", pattern: "y {Zahl}", aggregate: .median), .setComputed(name: "B", formula: "{A}", aggregate: .stdDev)]),
        ])
        #expect(set.aggregates == ["A": .max, "B": .stdDev])
    }
}
