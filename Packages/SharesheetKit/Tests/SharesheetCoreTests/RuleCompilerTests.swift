import Foundation
import Testing
@testable import SharesheetCore

@Suite struct RuleCompilerTests {
    private func rule(_ id: String = "r", enabled: Bool = true, match: RuleMatch = .all, _ conditions: [RuleCondition], _ actions: [RuleAction]) -> Rule {
        Rule(id: id, name: id, enabled: enabled, match: match, conditions: conditions, actions: actions)
    }
    private func contains(_ field: RuleField, _ value: String) -> RuleCondition {
        RuleCondition(field: field, op: .contains, value: value)
    }
    private func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func contextLowercasesFieldsAndCapsText() throws {
        let item = Item(
            id: ItemID(relativePath: "Unsorted/A.md"), type: .link, url: URL(string: "https://WWW.Apple.com/De")!,
            title: "Übersicht ÄPFEL", tags: ["Apple", "Tech"], created: Date(), note: "Meine NOTIZ")
        let long = String(repeating: "A", count: RuleContext.maxTextCharacters + 500)
        let json = try object(RuleContext.json(for: item, text: long, values: ["x", "Y"]))
        #expect(json["type"] as? String == "link")
        #expect(json["url"] as? String == "https://www.apple.com/de")
        #expect(json["domain"] as? String == "apple.com")
        #expect(json["title"] as? String == "übersicht äpfel")
        #expect(json["note"] as? String == "meine notiz")
        #expect(json["tag"] as? [String] == ["apple", "tech"])
        #expect((json["text"] as? String)?.count == RuleContext.maxTextCharacters)
        #expect(json["rv"] as? [String] == ["x", "Y"])
    }

    @Test func whitespaceRunsAreCollapsedInTheContextAndInConditionValues() throws {
        let item = Item(id: ItemID(relativePath: "Unsorted/A.md"), type: .text, title: "A\n  B", created: Date())
        let json = try object(RuleContext.json(for: item, text: "SVS\n  Konto-\tauszug ", values: []))
        #expect(json["text"] as? String == "svs konto- auszug")
        #expect(json["title"] as? String == "a b")
        let compiled = try #require(RuleCompiler.compile(RuleSet(rules: [rule("w", [contains(.text, "SVS \n Konto")], [.addTag("Tag  X")])])))
        #expect(compiled.values == ["svs konto", "Tag  X"])
    }

    @Test func compilerSkipsDisabledAndInvalidRules() {
        let set = RuleSet(rules: [
            rule("off", enabled: false, [contains(.url, "a")], [.addTag("x")]),
            rule("noCondition", [], [.addTag("x")]),
            rule("emptyValue", [contains(.url, "  ")], [.addTag("x")]),
            rule("noAction", [contains(.url, "a")], []),
            rule("emptyTag", [contains(.url, "a")], [.addTag(" ")]),
        ])
        #expect(RuleCompiler.compile(set) == nil)
        #expect(RuleCompiler.compile(.empty) == nil)
    }

    @Test func compileKeepsValuesOutOfExpressionsAndOrdersThem() throws {
        let nasty = #"it's "q" \ $x"#
        let set = RuleSet(rules: [
            rule("a", [contains(.url, "Apple.COM"), RuleCondition(field: .type, op: .is, value: "Link")], [.addTag("Apple"), .moveTo("Ablage")]),
            rule("b", [contains(.text, nasty)], [.addTag("Tag B")]),
        ])
        let compiled = try #require(RuleCompiler.compile(set))
        // Conditions are lowercased, action values keep their spelling; every value is used once.
        #expect(compiled.values == ["apple.com", "link", "Apple", "Ablage", nasty.lowercased(), "Tag B"])
        let text = String(decoding: compiled.decision, as: UTF8.self)
        #expect(!text.contains("apple.com") && !text.contains("Ablage") && !text.contains("$x"))
    }

    @Test func matchAnyMakesOneRowPerConditionWithSharedActionValues() throws {
        let set = RuleSet(rules: [rule("a", match: .any, [contains(.url, "Apple.com"), contains(.url, "microsoft.com")], [.addTag("Tech")])])
        let compiled = try #require(RuleCompiler.compile(set))
        #expect(compiled.values == ["apple.com", "microsoft.com", "Tech"])
        let graph = try object(compiled.decision)
        let table = try #require((graph["nodes"] as? [[String: Any]])?.first { $0["type"] as? String == "decisionTableNode" })
        let rows = try #require((table["content"] as? [String: Any])?["rules"] as? [[String: Any]])
        #expect(rows.count == 2)
    }

    @Test func matchAnyWithOneEmptyConditionDropsTheWholeRule() {
        let set = RuleSet(rules: [rule("a", match: .any, [contains(.url, "apple.com"), contains(.url, " ")], [.addTag("Tech")])])
        #expect(RuleCompiler.compile(set) == nil)
    }

    @Test func setDateTravelsAsAValueAndComesBackAsAPattern() throws {
        let pattern = "Ihr Einkauf am {Datum} um {Uhrzeit} Uhr"
        let set = RuleSet(rules: [
            rule("d", [contains(.text, "Einkauf")], [.addTag("Einkauf"), .setDate(pattern), .setDate("zweites {Datum}")]),
            rule("bad", [contains(.text, "x")], [.setDate("ohne Platzhalter")]),
        ])
        let compiled = try #require(RuleCompiler.compile(set))
        #expect(compiled.values == ["einkauf", "Einkauf", pattern])
        // The rule whose only action is an invalid pattern is dropped: none of its values are used.
        let result = Data(#"[{"setDate":"P1"},{"setDate":"P2","addTags":["x"]},{"setDate":"P1"},{"setDate":null}]"#.utf8)
        #expect(RuleCompiler.outcome(fromResult: result).datePatterns == ["P1", "P2"])
        #expect(RuleCompiler.outcome(fromResult: Data("[]".utf8)).datePatterns.isEmpty)
    }

    @Test func outcomeDeduplicatesTagsAndTakesFirstMove() {
        let result = Data(#"[{"addTags":["Apple","tech"],"moveTo":"A"},{"addTags":["apple"],"moveTo":"B"},{"moveTo":null,"addTags":null}]"#.utf8)
        #expect(RuleCompiler.outcome(fromResult: result) == RuleOutcome(tags: ["Apple", "tech"], moveTo: "A"))
    }

    @Test func outcomeOfEmptyOrBrokenResultIsEmpty() {
        #expect(RuleCompiler.outcome(fromResult: Data("[]".utf8)) == RuleOutcome(tags: [], moveTo: nil))
        #expect(RuleCompiler.outcome(fromResult: Data("garbage".utf8)) == RuleOutcome(tags: [], moveTo: nil))
        #expect(RuleCompiler.outcome(fromResult: Data(#"[{"moveTo":"  "}]"#.utf8)).moveTo == nil)
    }
}

@Suite struct RuleCompilerFieldTests {
    private func definitions(_ compiled: CompiledRules) throws -> [FieldDefinition] {
        try compiled.values.compactMap { try? JSONDecoder().decode(FieldDefinition.self, from: Data($0.utf8)) }
    }

    @Test func fieldsAndTitleTravelAsValuesAndComeBackInRuleOrder() throws {
        let cond = RuleCondition(field: .text, op: .contains, value: "Rechnung")
        let set = RuleSet(rules: [
            Rule(id: "a", name: "a", enabled: true, conditions: [cond], actions: [
                .setField(name: "Betrag", pattern: "Gesamt {Zahl}", op: .multiply, operand: 1.19),
                .setField(name: "Datum", pattern: "am {Datum}"),
                .setComputed(name: "Netto", formula: "{Betrag} / 1.19"),
                .setTitle("Tesla {Datum}"), .setField(name: "kaputt", pattern: "ohne"),
                .setComputed(name: "leer", formula: "1 + 2"),
            ])
        ])
        let compiled = try #require(RuleCompiler.compile(set))
        #expect(compiled.values.count == 5)
        #expect(compiled.values[0] == "rechnung")
        #expect(compiled.values[4] == "Tesla {Datum}")
        let expected = [
            FieldDefinition(name: "Betrag", pattern: "Gesamt {Zahl}", op: .multiply, operand: 1.19),
            FieldDefinition(name: "Datum", pattern: "am {Datum}"),
            FieldDefinition(name: "Netto", formula: "{Betrag} / 1.19"),
        ]
        #expect(try definitions(compiled) == expected)
        let graph = try #require(JSONSerialization.jsonObject(with: compiled.decision) as? [String: Any])
        let table = try #require((graph["nodes"] as? [[String: Any]])?.first { $0["type"] as? String == "decisionTableNode" })
        let row = try #require(((table["content"] as? [String: Any])?["rules"] as? [[String: Any]])?.first)
        #expect(row["out_setField"] as? String == "[rv[1], rv[2], rv[3]]")
        #expect(row["out_setTitle"] as? String == "rv[4]")

        let first = String(decoding: try JSONEncoder().encode(expected[0]), as: UTF8.self)
        let second = String(decoding: try JSONEncoder().encode(expected[1]), as: UTF8.self)
        let result = Data(
            (try JSONSerialization.data(withJSONObject: [
                ["setField": [first, second], "setTitle": "T1"], ["setField": [first], "setTitle": "T2"], ["setField": ["kaputt"]],
            ])))
        let outcome = RuleCompiler.outcome(fromResult: result)
        #expect(outcome.fieldDefinitions == [expected[0], expected[1]])
        #expect(outcome.titleTemplates == ["T1", "T2"])
    }
}
