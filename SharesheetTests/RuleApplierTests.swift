import Foundation
import Testing
import SharesheetCore
@testable import Sharesheet

private struct EvaluationError: Error {}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Int] = []
    var values: [Int] { lock.withLock { _values } }
    func add(_ value: Int) { lock.withLock { _values.append(value) } }
}

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
        _ env: ModelEnv, _ rules: [Rule], redirects: MoveRedirects? = nil, evaluate: RuleApplier.Evaluate? = nil
    ) throws -> RuleApplier {
        let engine = try RuleEngine()
        let set = RuleSet(rules: rules)
        return RuleApplier(
            store: env.store, index: env.index, redirects: redirects, rules: { set },
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

    @Test func thePreviewCountsExactlyWhatApplyAllChanges() async throws {
        let env = try ModelEnv()
        let appleRule = rule(apple, [.addTag("apple")])
        let svsRule = rule(svs, [.moveTo("Sozialversicherung")])
        let applier = try applier(env, [appleRule, svsRule])
        try await addLink(env, "https://apple.com/a")
        try await addLink(env, "https://apple.com/b", tags: ["Apple"])  // carries it: no change
        try await addLink(env, "https://example.com")
        try await addDocument(env, text: "SVS Kontoauszug")
        try await addDocument(env, text: "SVS Kontoauszug", in: CollectionPath(components: ["Ablage"]))  // sorted: stays
        let ids = try env.index.search(LibraryQuery(scope: .all)).map(\.id)

        let preview = await applier.preview(ids: ids)
        #expect(preview == RulePreview(items: 2, tagsAdded: 1, moved: 1))
        #expect(try await env.store.listItems().filter { $0.tags.contains("apple") }.isEmpty, "the preview writes nothing")

        #expect(await applier.applyAll(ids: ids, progress: { _ in }) == 2)
        let after = try env.index.search(LibraryQuery(scope: .all)).map(\.id)
        #expect(await applier.preview(ids: after) == RulePreview(items: 0, tagsAdded: 0, moved: 0))
        #expect(await applier.applyAll(ids: after, progress: { _ in }) == 0)
    }

    @Test func applyAllReportsProgressAndStopsWhenCancelled() async throws {
        let env = try ModelEnv()
        let applier = try applier(env, [rule(apple, [.addTag("apple")])])
        let a = try await addLink(env, "https://apple.com/a")
        let b = try await addLink(env, "https://apple.com/b")
        let steps = ProgressLog()
        #expect(await applier.applyAll(ids: [a.id, b.id], progress: { steps.add($0) }) == 2)
        #expect(steps.values == [1, 2])

        let c = try await addLink(env, "https://apple.com/c")
        let task = Task { await applier.applyAll(ids: [c.id], progress: { _ in }) }
        task.cancel()
        #expect(await task.value == 0)
        #expect(try await env.store.item(c.id).tags.isEmpty)
    }

    // MARK: Date from text

    private let pattern = "Ihr Einkauf am {Datum} um {Uhrzeit} Uhr"
    private var einkauf: [RuleCondition] { [RuleCondition(field: .text, op: .contains, value: "einkauf")] }

    private func expected(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    @Test func theDateComesFromTheTextAndASecondRunChangesNothing() async throws {
        let env = try ModelEnv()
        let item = try await addDocument(env, text: "Rechnung\nIhr Einkauf am 02.11.2026 um 15:08 Uhr\nDanke")
        let applier = try applier(env, [rule(einkauf, [.setDate(pattern)])])
        await applier.apply(to: item.id)
        let saved = try await env.store.item(item.id)
        #expect(saved.created == expected(2026, 11, 2, 15, 8))
        #expect(!saved.createdManual)
        #expect(try env.index.search(LibraryQuery(scope: .all)).first?.created == saved.created)
        #expect(await applier.plan(for: item.id) == nil)
    }

    @Test func aHandSetDateIsNeverChangedByARule() async throws {
        let env = try ModelEnv()
        let item = try await addDocument(env, text: "Ihr Einkauf am 02.11.2026 um 15:08 Uhr")
        let byHand = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await env.store.modify(item.id) { $0.created = byHand; $0.createdManual = true }
        let applier = try applier(env, [rule(einkauf, [.setDate(pattern)])])
        #expect(await applier.plan(for: item.id) == nil)
        await applier.apply(to: item.id)
        #expect(try await env.store.item(item.id).created == byHand)
        let ids = [item.id]
        #expect(await applier.preview(ids: ids) == RulePreview(items: 0, tagsAdded: 0, moved: 0))
    }

    @Test func impossibleDatesAndMissingTextChangeNothing() async throws {
        let env = try ModelEnv()
        let impossible = try await addDocument(env, text: "Ihr Einkauf am 31.02.2026 um 15:08 Uhr")
        let none = try await addDocument(env, text: "Einkauf ohne Datum")
        let applier = try applier(env, [rule(einkauf, [.setDate(pattern)])])
        #expect(await applier.plan(for: impossible.id) == nil)
        #expect(await applier.plan(for: none.id) == nil)
    }

    @Test func theFirstPatternThatFindsADateWins() async throws {
        let env = try ModelEnv()
        let item = try await addDocument(env, text: "Bestellt am 05.12.2026 Einkauf am 02.11.2026")
        let applier = try applier(env, [
            rule(einkauf, [.setDate("Ihr Einkauf am {Datum}")]),  // no match here
            rule(einkauf, [.setDate("Einkauf am {Datum}")]),
            rule(einkauf, [.setDate("Bestellt am {Datum}")]),
        ])
        #expect(await applier.plan(for: item.id)?.date == expected(2026, 11, 2, 0, 0))
    }

    @Test func dateTagAndMoveAreWrittenTogetherAndPreviewCountsTheDate() async throws {
        let env = try ModelEnv()
        let item = try await addDocument(env, text: "Ihr Einkauf am 02.11.2026 um 15:08 Uhr")
        let applier = try applier(env, [rule(einkauf, [.setDate(pattern), .addTag("Einkauf"), .moveTo("Belege")])])
        #expect(await applier.preview(ids: [item.id]) == RulePreview(items: 1, tagsAdded: 1, moved: 1, dates: 1))
        await applier.apply(to: item.id)
        let moved = try #require(try await env.store.listItems().first)
        #expect(moved.id.collection == CollectionPath(components: ["Belege"]))
        #expect(moved.tags == ["Einkauf"] && moved.created == expected(2026, 11, 2, 15, 8))
    }

    @Test func aMoveIsRecordedSoOpenScreensCanFollow() async throws {
        let env = try ModelEnv()
        let item = try await addDocument(env, text: "SVS Kontoauszug")
        let redirects = MoveRedirects()
        await (try applier(env, [rule(svs, [.moveTo("Sozialversicherung")])], redirects: redirects)).apply(to: item.id)
        let moved = try #require(try await env.store.listItems().first)
        #expect(moved.id != item.id)
        #expect(redirects.current(item.id) == moved.id)
    }

    @Test func tagNameLimitsAreCheckedSeparately() async throws {
        let env = try ModelEnv()
        let item = try await addLink(env)
        let over40 = String(repeating: "a", count: 41)
        let fourWords = "eins zwei drei vier"
        await (try applier(env, [rule(apple, [.addTag(over40), .addTag(fourWords), .addTag("drei kurze wörter")])])).apply(to: item.id)
        #expect(try await env.store.item(item.id).tags == ["drei kurze wörter"])
    }

    @Test func aFailingRunDoesNotHoldBackTheNextItem() async throws {
        let env = try ModelEnv()
        let first = try await addLink(env, "https://apple.com/a")
        let second = try await addLink(env, "https://apple.com/b")
        let engine = try RuleEngine()
        let failFirst = first.id
        let applier = try applier(env, [rule(apple, [.addTag("apple")])]) { set, item, text in
            if item.id == failFirst { throw EvaluationError() }
            return try await engine.outcome(for: set, item: item, text: text)
        }
        await applier.apply(to: first.id)
        await applier.apply(to: second.id)
        #expect(try await env.store.item(first.id).tags.isEmpty)
        #expect(try await env.store.item(second.id).tags == ["apple"])
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
