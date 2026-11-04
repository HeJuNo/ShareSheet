import Foundation
import Testing
import SharesheetCore
@testable import Sharesheet

struct RuleEngineTests {
    private func rule(_ id: String, _ conditions: [RuleCondition], _ actions: [RuleAction]) -> Rule {
        Rule(id: id, name: id, enabled: true, conditions: conditions, actions: actions)
    }
    private let appleRule = Rule(
        id: "apple", name: "Apple", enabled: true,
        conditions: [RuleCondition(field: .type, op: .is, value: "link"), RuleCondition(field: .url, op: .contains, value: "apple.com")],
        actions: [.addTag("apple")])
    private let svsRule = Rule(
        id: "svs", name: "SVS", enabled: true,
        conditions: [RuleCondition(field: .text, op: .contains, value: "SVS"), RuleCondition(field: .text, op: .contains, value: "Kontoauszug")],
        actions: [.moveTo("Sozialversicherung")])

    private func link(_ url: String, tags: [String] = []) -> Item {
        Item(id: ItemID(relativePath: "Unsorted/L.md"), type: .link, url: URL(string: url)!, title: "Link", tags: tags, created: Date())
    }
    private func pdf() -> Item {
        Item(id: ItemID(relativePath: "Unsorted/D.md"), type: .document, file: "_attachments/a.pdf", title: "Scan", created: Date())
    }

    @Test func appleLinkGetsTagApple() async throws {
        let engine = try RuleEngine()
        let set = RuleSet(rules: [appleRule])
        #expect(try await engine.outcome(for: set, item: link("https://www.apple.com/de/iphone"), text: "")
            == RuleOutcome(tags: ["apple"], moveTo: nil))
        #expect(try await engine.outcome(for: set, item: link("https://example.com"), text: "apple.com").tags.isEmpty)
        #expect(try await engine.outcome(for: set, item: pdf(), text: "apple.com").tags.isEmpty)
    }

    @Test func kontoauszugPdfMovesToSozialversicherung() async throws {
        let engine = try RuleEngine()
        let set = RuleSet(rules: [svsRule])
        #expect(try await engine.outcome(for: set, item: pdf(), text: "SVS Kontoauszug Oktober")
            == RuleOutcome(tags: [], moveTo: "Sozialversicherung"))
    }

    @Test func partialTextMatchesNothing() async throws {
        let engine = try RuleEngine()
        let outcome = try await engine.outcome(for: RuleSet(rules: [svsRule]), item: pdf(), text: "Nur die SVS")
        #expect(outcome == RuleOutcome(tags: [], moveTo: nil))
    }

    @Test func upperCaseTextAndValuesStillMatch() async throws {
        let engine = try RuleEngine()
        let outcome = try await engine.outcome(for: RuleSet(rules: [svsRule]), item: pdf(), text: "svs KONTOAUSZUG, Übersicht")
        #expect(outcome.moveTo == "Sozialversicherung")
    }

    @Test func twoRulesWithTheSameTagGiveItOnce() async throws {
        let engine = try RuleEngine()
        let other = rule("apple2", [RuleCondition(field: .domain, op: .contains, value: "apple")], [.addTag("Apple"), .moveTo("Tech")])
        let outcome = try await engine.outcome(for: RuleSet(rules: [appleRule, other]), item: link("https://apple.com"), text: "")
        #expect(outcome == RuleOutcome(tags: ["apple"], moveTo: "Tech"))
    }

    @Test func tagConditionMatchesAnItemTag() async throws {
        let engine = try RuleEngine()
        let set = RuleSet(rules: [rule("t", [RuleCondition(field: .tag, op: .is, value: "Steuer")], [.moveTo("Finanzen")])])
        #expect(try await engine.outcome(for: set, item: link("https://a.b", tags: ["steuer", "x"]), text: "").moveTo == "Finanzen")
        #expect(try await engine.outcome(for: set, item: link("https://a.b", tags: ["steuern"]), text: "").moveTo == nil)
    }

    @Test func specialCharactersInValuesAreMatchedLiterally() async throws {
        let engine = try RuleEngine()
        let value = #"it's "q" \ $x"#
        let set = RuleSet(rules: [rule("n", [RuleCondition(field: .text, op: .contains, value: value)], [.addTag("hit")])])
        #expect(try await engine.outcome(for: set, item: pdf(), text: "vorher \(value) nachher").tags == ["hit"])
        #expect(try await engine.outcome(for: set, item: pdf(), text: "nichts").tags.isEmpty)
    }

    @Test func noValidRuleMeansEmptyOutcome() async throws {
        let engine = try RuleEngine()
        let empty = rule("e", [], [.addTag("x")])
        #expect(try await engine.outcome(for: RuleSet(rules: [empty]), item: pdf(), text: "x") == RuleOutcome(tags: [], moveTo: nil))
    }

    @Test func changedRulesAreEvaluatedFresh() async throws {
        let engine = try RuleEngine()
        _ = try await engine.outcome(for: RuleSet(rules: [appleRule]), item: link("https://apple.com"), text: "")
        let changed = rule("x", [RuleCondition(field: .domain, op: .contains, value: "apple")], [.addTag("anderes")])
        #expect(try await engine.outcome(for: RuleSet(rules: [changed]), item: link("https://apple.com"), text: "").tags == ["anderes"])
    }
}
