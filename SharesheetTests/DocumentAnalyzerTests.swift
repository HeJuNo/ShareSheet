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

@MainActor
struct DocumentAnalyzerTests {
    private func makePDF(_ lines: [String], in dir: URL) throws -> URL {
        let url = dir.appending(path: "doc-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        for (row, line) in lines.enumerated() {
            let string = NSAttributedString(
                string: line, attributes: [kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("Helvetica" as CFString, 14, nil)])
            context.textPosition = CGPoint(x: 40, y: 740 - Double(row) * 24)
            CTLineDraw(CTLineCreateWithAttributedString(string), context)
        }
        context.endPDFPage()
        context.closePDF()
        return url
    }

    private let invoiceLines = [
        "Rechnung Nummer 4711 Tischlerei Eichenholz", "Rechnungsbetrag Hobelbank Leimzwingen Eichenholz",
        "Lieferung Eichenholz Hobelbank Zahlungsziel",
    ]

    @discardableResult
    private func addPDF(
        _ env: ModelEnv, lines: [String]? = nil, tags: [String] = [], title: String = "Doc"
    ) async throws -> Item {
        let pdf = try makePDF(lines ?? invoiceLines, in: env.base)
        let item = try await env.store.create(
            ItemDraft(type: .document, title: title, tags: tags, fileSource: pdf), in: .unsorted)
        try env.index.upsert(item)
        return item
    }

    private func analyzer(
        _ env: ModelEnv, store: (any ItemStore)? = nil, tagger: FakeTagger, mode: TagMode
    ) -> DocumentAnalyzer {
        DocumentAnalyzer(store: store ?? env.store, index: env.index, tagger: tagger, tagMode: { mode })
    }

    private func tags(_ env: ModelEnv, _ item: Item) async throws -> [String] {
        try await env.store.item(item.id).tags
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
}
