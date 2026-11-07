import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Sharesheet
import SharesheetCore

private struct FakeTaggerError: Error {}

private final class FakeTagger: DocumentTagging, @unchecked Sendable {
    var answer: String?
    var throwing = false
    var available = true
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }

    init(answer: String? = nil) { self.answer = answer }

    var isAvailable: Bool { available }

    func tag(forText text: String, existingTags: [String]) async throws -> String? {
        lock.withLock { _calls += 1 }
        if throwing { throw FakeTaggerError() }
        return answer
    }
}

/// Throws `.downloading` for the first `attachmentURL` call, then behaves like the wrapped store.
private final class FlakyStore: ItemStore, @unchecked Sendable {
    let base: FolderItemStore
    private let lock = NSLock()
    private var failuresLeft = 1

    init(_ base: FolderItemStore) { self.base = base }

    func listItems() async throws -> [Item] { try await base.listItems() }
    func item(_ id: ItemID) async throws -> Item { try await base.item(id) }
    func findItem(url: URL) async throws -> Item? { try await base.findItem(url: url) }
    func create(_ draft: ItemDraft, in collection: CollectionPath, willWrite: @Sendable (ItemID) throws -> Void) async throws -> Item {
        try await base.create(draft, in: collection, willWrite: willWrite)
    }
    func update(_ item: Item) async throws -> Item { try await base.update(item) }
    func modify(_ id: ItemID, _ transform: @Sendable (inout Item) throws -> Void) async throws -> Item {
        try await base.modify(id, transform)
    }
    func move(_ id: ItemID, to collection: CollectionPath) async throws -> Item { try await base.move(id, to: collection) }
    func delete(_ id: ItemID) async throws { try await base.delete(id) }
    func addAttachment(from source: URL, preferredName: String) async throws -> String {
        try await base.addAttachment(from: source, preferredName: preferredName)
    }
    func attachmentURL(_ relativePath: String) async throws -> URL {
        let fail = lock.withLock { () -> Bool in
            if failuresLeft > 0 { failuresLeft -= 1; return true }
            return false
        }
        if fail { throw StoreError.downloading(relativePath) }
        return try await base.attachmentURL(relativePath)
    }
    func collections() async throws -> [CollectionPath] { try await base.collections() }
    func createCollection(named name: String, in parent: CollectionPath) async throws -> CollectionPath {
        try await base.createCollection(named: name, in: parent)
    }
    func deleteCollection(_ path: CollectionPath, moveItemsTo destination: CollectionPath?) async throws {
        try await base.deleteCollection(path, moveItemsTo: destination)
    }
    func changes() -> AsyncStream<Void> { base.changes() }
}

/// Counts `attachmentURL` calls.
private final class SpyStore: ItemStore, @unchecked Sendable {
    let base: FolderItemStore
    private let lock = NSLock()
    private var _attachmentCalls = 0
    var attachmentCalls: Int { lock.withLock { _attachmentCalls } }

    init(_ base: FolderItemStore) { self.base = base }

    func listItems() async throws -> [Item] { try await base.listItems() }
    func item(_ id: ItemID) async throws -> Item { try await base.item(id) }
    func findItem(url: URL) async throws -> Item? { try await base.findItem(url: url) }
    func create(_ draft: ItemDraft, in collection: CollectionPath, willWrite: @Sendable (ItemID) throws -> Void) async throws -> Item {
        try await base.create(draft, in: collection, willWrite: willWrite)
    }
    func update(_ item: Item) async throws -> Item { try await base.update(item) }
    func modify(_ id: ItemID, _ transform: @Sendable (inout Item) throws -> Void) async throws -> Item {
        try await base.modify(id, transform)
    }
    func move(_ id: ItemID, to collection: CollectionPath) async throws -> Item { try await base.move(id, to: collection) }
    func delete(_ id: ItemID) async throws { try await base.delete(id) }
    func addAttachment(from source: URL, preferredName: String) async throws -> String {
        try await base.addAttachment(from: source, preferredName: preferredName)
    }
    func attachmentURL(_ relativePath: String) async throws -> URL {
        lock.withLock { _attachmentCalls += 1 }
        return try await base.attachmentURL(relativePath)
    }
    func collections() async throws -> [CollectionPath] { try await base.collections() }
    func createCollection(named name: String, in parent: CollectionPath) async throws -> CollectionPath {
        try await base.createCollection(named: name, in: parent)
    }
    func deleteCollection(_ path: CollectionPath, moveItemsTo destination: CollectionPath?) async throws {
        try await base.deleteCollection(path, moveItemsTo: destination)
    }
    func changes() -> AsyncStream<Void> { base.changes() }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DocumentAnalyzerTests {
    private let invoiceLines = [
        "Rechnung Nummer 4711 Tischlerei Eichenholz", "Rechnungsbetrag Hobelbank Leimzwingen Eichenholz",
        "Lieferung Eichenholz Hobelbank Zahlungsziel",
    ]

    @discardableResult
    private func addPDF(
        _ env: ModelEnv, lines: [String]? = nil, tags: [String] = [], title: String = "Doc"
    ) async throws -> Item {
        let pdf = try makeTestPDF(in: env.base, lines: lines ?? invoiceLines)
        let item = try await env.store.create(
            ItemDraft(type: .document, title: title, tags: tags, fileSource: pdf), in: .unsorted)
        try env.index.upsert(item)
        return item
    }

    private func analyzer(
        _ env: ModelEnv, store: (any ItemStore)? = nil, tagger: FakeTagger, mode: TagMode, rules: (any RuleApplying)? = nil
    ) -> DocumentAnalyzer {
        DocumentAnalyzer(store: store ?? env.store, index: env.index, tagger: tagger, tagMode: { mode }, rules: rules)
    }

    private func tags(_ env: ModelEnv, _ item: Item) async throws -> [String] {
        try await env.store.item(item.id).tags
    }

    @Test func rulesRunOncePerAnalyzedDocumentAfterItsTextIsStored() async throws {
        let env = try ModelEnv()
        let item = try await addPDF(env)
        let index = env.index
        let rules = RecordingRules(probe: { try? index.analysisText(forItem: $0) })
        let runner = analyzer(env, tagger: FakeTagger(), mode: .off, rules: rules)
        #expect(await runner.runPending() == 1)
        #expect(rules.applied == [item.id])
        #expect(rules.probes.first??.contains("Eichenholz") == true)
        #expect(await runner.runPending() == 0)
        #expect(rules.applied == [item.id])
    }

    @Test func aKontoauszugPdfIsSortedIntoSozialversicherungThroughTheRealRuleEngine() async throws {
        let env = try ModelEnv()
        let hit = try await addPDF(env, lines: ["SVS Sozialversicherung", "Kontoauszug Oktober Buchung"], title: "Hit")
        let miss = try await addPDF(env, lines: ["SVS Beitragsvorschreibung Oktober"], title: "Miss")
        let sorted = try await addPDF(env, lines: ["SVS Kontoauszug Oktober"], title: "Sorted")
        let moved = try await env.store.move(sorted.id, to: CollectionPath(components: ["Ablage"]))
        try env.index.remove(sorted.id)
        try env.index.upsert(moved)
        let set = RuleSet(rules: [Rule(
            id: "svs", name: "SVS", enabled: true,
            conditions: [RuleCondition(field: .text, op: .contains, value: "SVS"), RuleCondition(field: .text, op: .contains, value: "Kontoauszug")],
            actions: [.moveTo("Sozialversicherung")])])
        let engine = try RuleEngine()
        let rules = RuleApplier(
            store: env.store, index: env.index, rules: { set },
            evaluate: { set, item, text in try await engine.outcome(for: set, item: item, text: text) })
        let target = CollectionPath(components: ["Sozialversicherung"])
        _ = await analyzer(env, tagger: FakeTagger(), mode: .off, rules: rules).runPending()
        let items = try await env.store.listItems()
        #expect(items.first { $0.title == "Hit" }?.id.collection == target)
        #expect(items.first { $0.title == "Miss" }?.id.collection == .unsorted)
        #expect(items.first { $0.title == "Sorted" }?.id.collection == CollectionPath(components: ["Ablage"]))
        #expect(try env.index.analysis(forItem: moved.id) != nil, "the sorted PDF was analyzed, so the rules did run for it")
        _ = (hit, miss)
    }

    @Test func rulesRunAlsoForFilesThatCannotBeRead() async throws {
        let env = try ModelEnv()
        let broken = env.base.appending(path: "broken.pdf")
        try Data("not a pdf".utf8).write(to: broken)
        let item = try await env.store.create(ItemDraft(type: .document, title: "Broken", fileSource: broken), in: .unsorted)
        try env.index.upsert(item)
        let rules = RecordingRules()
        #expect(await analyzer(env, tagger: FakeTagger(), mode: .off, rules: rules).runPending() == 1)
        #expect(rules.applied == [item.id])
    }

    @Test func rulesWaitUntilASkippedDocumentIsAnalyzed() async throws {
        let env = try ModelEnv()
        let item = try await addPDF(env)
        let rules = RecordingRules()
        let runner = analyzer(env, store: FlakyStore(env.store), tagger: FakeTagger(), mode: .off, rules: rules)
        #expect(await runner.runPending() == 0)
        #expect(rules.applied.isEmpty)
        #expect(await runner.runPending() == 1)
        #expect(rules.applied == [item.id])
    }

    @Test func analyzesADocumentAndStoresTextKeywordsAndTag() async throws {
        let env = try ModelEnv()
        try env.index.upsert(try await env.store.create(ItemDraft(type: .text, title: "Other", tags: ["Rechnung"]), in: .unsorted))
        let item = try await addPDF(env)
        let tagger = FakeTagger(answer: "Rechnungen")
        let count = await analyzer(env, tagger: tagger, mode: .automatic).runPending()
        #expect(count == 1)
        #expect(try await tags(env, item) == ["Rechnung"])
        let hits = try env.index.search(LibraryQuery(text: "Hobelbank", scope: .all))
        #expect(hits.map(\.id) == [item.id])
        let analysis = try #require(try env.index.analysis(forItem: item.id))
        #expect(!analysis.keywords.isEmpty)
        #expect(analysis.suggestedTag == nil)
        #expect(try env.index.analysisCandidates().isEmpty)
    }

    @Test func suggestModeStoresASuggestionAndLeavesTagsAlone() async throws {
        let env = try ModelEnv()
        let item = try await addPDF(env)
        let tagger = FakeTagger(answer: "Rechnung")
        _ = await analyzer(env, tagger: tagger, mode: .suggest).runPending()
        #expect(try await tags(env, item).isEmpty)
        #expect(try env.index.analysis(forItem: item.id)?.suggestedTag == "Rechnung")
    }

    @Test func suggestModeSuggestsNothingForATagTheItemHas() async throws {
        let env = try ModelEnv()
        let item = try await addPDF(env, tags: ["rechnung"])
        let count = await analyzer(env, tagger: FakeTagger(answer: "Rechnung"), mode: .suggest).runPending()
        #expect(count == 1)
        let analysis = try #require(try env.index.analysis(forItem: item.id))
        #expect(analysis.suggestedTag == nil)
        #expect(!analysis.keywords.isEmpty)
        #expect(try await tags(env, item) == ["rechnung"])
    }

    @Test func offModeSkipsTheModelButKeepsTextAndKeywords() async throws {
        let env = try ModelEnv()
        let item = try await addPDF(env)
        let tagger = FakeTagger(answer: "Rechnung")
        let count = await analyzer(env, tagger: tagger, mode: .off).runPending()
        #expect(count == 1)
        #expect(tagger.calls == 0)
        #expect(try await tags(env, item).isEmpty)
        #expect(try env.index.analysis(forItem: item.id)?.keywords.isEmpty == false)
        #expect(try env.index.search(LibraryQuery(text: "Hobelbank", scope: .all)).count == 1)
    }

    @Test func aRemovedTagIsNotAppliedAgain() async throws {
        let env = try ModelEnv()
        let item = try await addPDF(env)
        let tagger = FakeTagger(answer: "Rechnung")
        let runner = analyzer(env, tagger: tagger, mode: .automatic)
        _ = await runner.runPending()
        #expect(try await tags(env, item) == ["Rechnung"])
        let updated = try await env.store.modify(item.id) { $0.tags = [] }
        try env.index.upsert(updated)
        let second = await runner.runPending()
        #expect(second == 0)
        #expect(try await tags(env, item).isEmpty)
        #expect(tagger.calls == 1)
    }

    @Test func offloadedFileIsSkippedAndRetried() async throws {
        let env = try ModelEnv()
        let item = try await addPDF(env)
        let tagger = FakeTagger(answer: "Rechnung")
        let runner = analyzer(env, store: FlakyStore(env.store), tagger: tagger, mode: .automatic)
        #expect(await runner.runPending() == 0)
        #expect(try env.index.analysis(forItem: item.id) == nil)
        #expect(tagger.calls == 0)
        #expect(await runner.runPending() == 1)
        #expect(try env.index.analysis(forItem: item.id) != nil)
        #expect(try await tags(env, item) == ["Rechnung"])
    }

    @Test func unreadableFileIsMarkedAnalyzedWithEmptyText() async throws {
        let env = try ModelEnv()
        let broken = env.base.appending(path: "broken.pdf")
        try Data("not a pdf".utf8).write(to: broken)
        let item = try await env.store.create(ItemDraft(type: .document, title: "Broken", fileSource: broken), in: .unsorted)
        try env.index.upsert(item)
        let tagger = FakeTagger(answer: "Rechnung")
        let runner = analyzer(env, tagger: tagger, mode: .automatic)
        #expect(await runner.runPending() == 1)
        #expect(tagger.calls == 0)
        let analysis = try #require(try env.index.analysis(forItem: item.id))
        #expect(analysis.keywords.isEmpty)
        #expect(try env.index.analysisText(forItem: item.id) == "")
        #expect(try await tags(env, item).isEmpty)
        #expect(await runner.runPending() == 0)
    }

    @Test func modelErrorsAndJunkAnswersGiveNoTag() async throws {
        let answers: [String?] = [nil, "", String(repeating: "x", count: 41), "eins zwei drei vier"]
        for answer in answers + ["throw"] {
            let env = try ModelEnv()
            let item = try await addPDF(env)
            let tagger = FakeTagger(answer: answer == "throw" ? nil : answer)
            tagger.throwing = answer == "throw"
            let runner = analyzer(env, tagger: tagger, mode: .automatic)
            #expect(await runner.runPending() == 1)
            #expect(tagger.calls == 1)
            #expect(try await tags(env, item).isEmpty)
            #expect(try env.index.analysis(forItem: item.id)?.keywords.isEmpty == false)
            #expect(try env.index.search(LibraryQuery(text: "Hobelbank", scope: .all)).count == 1)
            #expect(await runner.runPending() == 0)
            #expect(tagger.calls == 1)
        }
    }

    @Test func webItemUsesItsArchiveText() async throws {
        let env = try ModelEnv()
        let created = try await env.store.create(
            ItemDraft(type: .link, url: URL(string: "https://example.com/a"), title: "Page"), in: .unsorted)
        let item = try await env.store.modify(created.id) { $0.archive = "_attachments/page.html" }
        try env.index.upsert(item)
        try env.index.setArchiveText(
            "Quartalsabrechnung Hobelbank Eichenholz Hobelbank Zahlungsziel", forArchive: "_attachments/page.html")
        let tagger = FakeTagger(answer: "Abrechnung")
        let count = await analyzer(env, tagger: tagger, mode: .automatic).runPending()
        #expect(count == 1)
        #expect(tagger.calls == 1)
        #expect(try await tags(env, item) == ["Abrechnung"])
        let analysis = try #require(try env.index.analysis(forItem: item.id))
        #expect(analysis.keywords.contains { $0.term.lowercased() == "hobelbank" })
        #expect(try env.index.analysisText(forItem: item.id)?.contains("Quartalsabrechnung") == true)
    }

    @Test func webItemWithoutArchiveTextIsSkippedUntilTheTextArrives() async throws {
        let env = try ModelEnv()
        let created = try await env.store.create(
            ItemDraft(type: .link, url: URL(string: "https://example.com/a"), title: "Page"), in: .unsorted)
        let item = try await env.store.modify(created.id) { $0.archive = "_attachments/page.html" }
        try env.index.upsert(item)
        let run = analyzer(env, tagger: FakeTagger(answer: "Abrechnung"), mode: .suggest)
        #expect(await run.runPending() == 0)
        #expect(try env.index.analysis(forItem: item.id) == nil)
        try env.index.setArchiveText("", forArchive: "_attachments/page.html")
        #expect(await run.runPending() == 0)
        #expect(try env.index.analysis(forItem: item.id) == nil)
        try env.index.setArchiveText("Quartalsabrechnung Hobelbank Eichenholz", forArchive: "_attachments/page.html")
        #expect(await run.runPending() == 1)
        #expect(try env.index.analysis(forItem: item.id)?.suggestedTag == "Abrechnung")
    }

    @Test func existingTagsAreOnlyAddedToNeverReplaced() async throws {
        let env = try ModelEnv()
        let item = try await addPDF(env, tags: ["x"])
        let tagger = FakeTagger(answer: "Rechnung")
        _ = await analyzer(env, tagger: tagger, mode: .automatic).runPending()
        #expect(try await tags(env, item) == ["x", "Rechnung"])
    }

    @Test func unsupportedFileTypesAreMarkedAnalyzedWithoutTouchingTheFile() async throws {
        let env = try ModelEnv()
        let spy = SpyStore(env.store)
        var items: [Item] = []
        for name in ["clip.mp4", "bundle.zip", "noextension"] {
            let file = env.base.appending(path: name)
            try Data("data".utf8).write(to: file)
            let item = try await env.store.create(ItemDraft(type: .document, title: name, fileSource: file), in: .unsorted)
            try env.index.upsert(item)
            items.append(item)
        }
        let tagger = FakeTagger(answer: "Rechnung")
        let runner = analyzer(env, store: spy, tagger: tagger, mode: .automatic)
        #expect(await runner.runPending() == 3)
        #expect(spy.attachmentCalls == 0)
        #expect(tagger.calls == 0)
        for item in items { #expect(try env.index.analysis(forItem: item.id) != nil) }
        #expect(try env.index.analysisCandidates().isEmpty)
        #expect(await runner.runPending() == 0)
    }

    @Test func automaticModeDoesNotAddATagInAnotherSpelling() async throws {
        let env = try ModelEnv()
        try env.index.upsert(try await env.store.create(ItemDraft(type: .text, title: "Other", tags: ["Rechnung"]), in: .unsorted))
        let item = try await addPDF(env, tags: ["rechnung"])
        _ = await analyzer(env, tagger: FakeTagger(answer: "Rechnung"), mode: .automatic).runPending()
        #expect(try await tags(env, item) == ["rechnung"])
    }

    @Test func onlyTheMostFrequentTermsAreLookedUp() {
        var counts = Dictionary(uniqueKeysWithValues: (0..<1000).map { ("term\(String(format: "%04d", $0))", 1) })
        counts["alpha"] = 5
        counts["zulu"] = 5
        let top = DocumentAnalyzer.topTerms(counts, limit: DocumentAnalyzer.maxKeywordCandidates)
        #expect(top.count == 300)
        #expect(top["alpha"] == 5 && top["zulu"] == 5)
        // Ties of count 1 go to the alphabetically first terms.
        #expect(top["term0297"] == 1 && top["term0298"] == nil)
        let small = ["a": 1, "b": 2]
        #expect(DocumentAnalyzer.topTerms(small, limit: 300) == small)
    }

    @Test func aDocumentWithManyDistinctTermsStillGetsKeywords() async throws {
        let env = try ModelEnv()
        let words = (0..<1000).map { "wort" + String(UnicodeScalar(97 + $0 / 676)!) + String(UnicodeScalar(97 + $0 / 26 % 26)!) + String(UnicodeScalar(97 + $0 % 26)!) }
        let url = env.base.appending(path: "many.txt")
        try Data((["Hobelbank Hobelbank Hobelbank"] + words).joined(separator: " ").utf8).write(to: url)
        let item = try await env.store.create(ItemDraft(type: .document, title: "Many", fileSource: url), in: .unsorted)
        try env.index.upsert(item)
        #expect(await analyzer(env, tagger: FakeTagger(), mode: .off).runPending() == 1)
        let keywords = try #require(try env.index.analysis(forItem: item.id)).keywords
        #expect(keywords.first?.term.lowercased() == "hobelbank")
    }
}
