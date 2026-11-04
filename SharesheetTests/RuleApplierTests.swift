import Foundation
import Testing
import SharesheetCore
@testable import Sharesheet

private struct EvaluationError: Error {}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RuleApplierTests {
    private func rule(
        _ conditions: [RuleCondition], _ actions: [RuleAction], enabled: Bool = true
    ) -> Rule {
        Rule(id: UUID().uuidString, name: "r", enabled: enabled, conditions: conditions, actions: actions)
    }
    private let apple = [RuleCondition(field: .url, op: .contains, value: "apple.com")]
    private let svs = [RuleCondition(field: .text, op: .contains, value: "svs"), RuleCondition(field: .text, op: .contains, value: "kontoauszug")]

    private func applier(
        _ env: ModelEnv, _ rules: [Rule], evaluate: RuleApplier.Evaluate? = nil
    ) throws -> RuleApplier {
        let engine = try RuleEngine()
        let set = RuleSet(rules: rules)
        return RuleApplier(
            store: env.store, index: env.index, rules: { set },
            evaluate: evaluate ?? { set, item, text in try await engine.outcome(for: set, item: item, text: text) })
    }

    @discardableResult
    private func addLink(_ env: ModelEnv, _ url: String = "https://www.apple.com/de", tags: [String] = [], in collection: CollectionPath = .unsorted) async throws -> Item {
        let item = try await env.store.create(ItemDraft(type: .link, url: URL(string: url)!, title: "Link", tags: tags), in: collection)
        try env.index.upsert(item)
        return item
    }

    @discardableResult
    private func addDocument(_ env: ModelEnv, text: String, in collection: CollectionPath = .unsorted) async throws -> Item {
        let file = env.base.appending(path: "scan-\(UUID().uuidString).pdf")
        try Data("%PDF".utf8).write(to: file)
        let item = try await env.store.create(ItemDraft(type: .document, title: "Scan", fileSource: file), in: collection)
        try env.index.upsert(item)
        try env.index.setAnalysis(source: try #require(item.file), text: text, keywords: [], suggestedTag: nil)
        return item
    }

    private func ids(_ env: ModelEnv) throws -> [String] {
        try env.index.search(LibraryQuery(scope: .all)).map(\.id.relativePath)
    }

    @Test func tagsALinkOnceAndASecondRunChangesNothing() async throws {
        let env = try ModelEnv()
        let item = try await addLink(env)
        let applier = try applier(env, [rule(apple, [.addTag("apple")])])
        await applier.apply(to: item.id)
        #expect(try await env.store.item(item.id).tags == ["apple"])
        await applier.apply(to: item.id)
        #expect(try await env.store.item(item.id).tags == ["apple"])
    }

    @Test func movesAPdfFromUnsortedToANewCollectionAndUpdatesTheIndex() async throws {
        let env = try ModelEnv()
        let item = try await addDocument(env, text: "SVS Kontoauszug Oktober")
        await (try applier(env, [rule(svs, [.moveTo("Sozialversicherung")])])).apply(to: item.id)
        let collections = try await env.store.collections()
        #expect(collections.contains(CollectionPath(components: ["Sozialversicherung"])))
        let all = try await env.store.listItems()
        #expect(all.count == 1 && all[0].id.collection == CollectionPath(components: ["Sozialversicherung"]))
        #expect(try ids(env) == [all[0].id.relativePath])
    }

    @Test func movingTwiceDoesNotCreateASecondCollection() async throws {
        let env = try ModelEnv()
        let first = try await addDocument(env, text: "svs kontoauszug")
        let second = try await addDocument(env, text: "SVS KONTOAUSZUG")
        let applier = try applier(env, [rule(svs, [.moveTo("sozialversicherung")])])
        await applier.apply(to: first.id)
        await applier.apply(to: second.id)
        let names = try await env.store.collections().map(\.relativePath).filter { $0.lowercased().hasPrefix("sozial") }
        #expect(names.count == 1)
    }

    @Test func leavesAnAlreadySortedItemAlone() async throws {
        let env = try ModelEnv()
        let ablage = CollectionPath(components: ["Ablage"])
        let item = try await addDocument(env, text: "SVS Kontoauszug", in: ablage)
        await (try applier(env, [rule(svs, [.moveTo("Sozialversicherung")])])).apply(to: item.id)
        #expect(try await env.store.item(item.id).id.collection == ablage)
        #expect(!(try await env.store.collections()).contains(CollectionPath(components: ["Sozialversicherung"])))
    }

    @Test func neverRemovesTags() async throws {
        let env = try ModelEnv()
        let item = try await addLink(env, tags: ["Wichtig"])
        await (try applier(env, [rule(apple, [.addTag("apple")])])).apply(to: item.id)
        #expect(try await env.store.item(item.id).tags == ["Wichtig", "apple"])
    }

    @Test func reusesTheSpellingOfAnExistingTag() async throws {
        let env = try ModelEnv()
        try await addLink(env, "https://example.org", tags: ["Apple"])
        let item = try await addLink(env)
        await (try applier(env, [rule(apple, [.addTag("apple")])])).apply(to: item.id)
        #expect(try await env.store.item(item.id).tags == ["Apple"])
    }

    @Test func skipsUnusableTagNamesButKeepsTheOthers() async throws {
        let env = try ModelEnv()
        let item = try await addLink(env)
        let tooLong = "ein sehr langer tag mit vielen wörtern"
        await (try applier(env, [rule(apple, [.addTag(tooLong), .addTag("apple")])])).apply(to: item.id)
        #expect(try await env.store.item(item.id).tags == ["apple"])
    }

    @Test func unusableCollectionNamesDoNothing() async throws {
        let env = try ModelEnv()
        let item = try await addLink(env)
        for target in ["../Elsewhere", "_attachments", ".hidden", "A//B", " "] {
            await (try applier(env, [rule(apple, [.moveTo(target)])])).apply(to: item.id)
            #expect(try await env.store.item(item.id).id.collection == .unsorted, "target \(target)")
        }
    }

    @Test func invalidOrDisabledRulesDoNothing() async throws {
        let env = try ModelEnv()
        let item = try await addLink(env)
        let rules = [
            rule(apple, [.addTag("off")], enabled: false), rule([], [.addTag("empty")]),
            rule([RuleCondition(field: .url, op: .contains, value: "")], [.addTag("blank")]),
        ]
        await (try applier(env, rules)).apply(to: item.id)
        #expect(try await env.store.item(item.id).tags.isEmpty)
    }

    @Test func aMissingItemDoesNotCrash() async throws {
        let env = try ModelEnv()
        await (try applier(env, [rule(apple, [.addTag("apple")])])).apply(to: ItemID(relativePath: "Unsorted/Gone.md"))
    }

    @Test func anItemDeletedDuringEvaluationWritesNothing() async throws {
        let env = try ModelEnv()
        let item = try await addLink(env)
        let store = env.store
        let applier = try applier(env, [rule(apple, [.addTag("apple")])]) { _, item, _ in
            try await store.delete(item.id)
            return RuleOutcome(tags: ["apple"], moveTo: "Elsewhere")
        }
        await applier.apply(to: item.id)
        #expect(try await store.listItems().isEmpty)
        #expect(!(try await store.collections()).contains(CollectionPath(components: ["Elsewhere"])))
    }

    @Test func anEngineFailureWritesNothing() async throws {
        let env = try ModelEnv()
        let item = try await addLink(env)
        let applier = try applier(env, [rule(apple, [.addTag("apple")])]) { _, _, _ in throw EvaluationError() }
        await applier.apply(to: item.id)
        #expect(try await env.store.item(item.id).tags.isEmpty)
    }
}
