import Testing
import Foundation
@testable import SharesheetCore

private func makeInbox() throws -> (Inbox, URL) {
    let root = try makeTempDirectory()
    return (Inbox(root: root), root)
}

@Test func enqueueCopiesLargeFileByURL() throws {
    let (inbox, root) = try makeInbox()
    let request = ShareRequest.fixture(entries: [.fixture(fileName: "big.mov")])
    let big = try sparseFile(bytes: 512 * 1024 * 1024)
    try inbox.enqueue(request, files: ["big.mov": big])
    let copied = root.appending(path: request.id.uuidString).appending(path: "big.mov")
    #expect(try FileManager.default.attributesOfItem(atPath: copied.path)[.size] as? Int == 512 * 1024 * 1024)
}

@Test func pendingIsOldestFirstAndSkipsDirsWithoutRequest() throws {
    let (inbox, root) = try makeInbox()
    let newer = ShareRequest.fixture(created: Date(timeIntervalSince1970: 2000))
    let older = ShareRequest.fixture(created: Date(timeIntervalSince1970: 1000))
    try inbox.enqueue(newer, files: [:])
    try inbox.enqueue(older, files: [:])
    try FileManager.default.createDirectory(
        at: root.appending(path: "half-written"), withIntermediateDirectories: true)
    let pending = try inbox.pending()
    #expect(pending.map(\.request.id) == [older.id, newer.id])
    #expect(pending[0].directory.lastPathComponent == older.id.uuidString)
    try inbox.remove(older.id)
    #expect(try inbox.pending().map(\.request.id) == [newer.id])
}

private func importer(_ inbox: Inbox, _ store: any ItemStore) -> InboxImporter {
    InboxImporter(inbox: inbox, store: store)
}

@Test func importSingleCreatesItemInChosenCollection() async throws {
    let (inbox, _) = try makeInbox()
    let (store, _) = try makeStore()
    let billa = CollectionPath(components: ["Billa"])
    _ = try await store.createCollection(named: "Billa", in: .root)
    try inbox.enqueue(
        .fixture(collection: billa, tags: ["x"], note: "n", favorite: true), files: [:])
    let report = await importer(inbox, store).importAll()
    #expect(report.imported == [ItemID(relativePath: "Billa/T.md")])
    #expect(report.failed == 0)
    #expect(try inbox.pending().isEmpty)
    let item = try await store.item(report.imported[0])
    #expect(item.tags == ["x"] && item.note == "n" && item.favorite)
}

@Test func importMultiCreatesNewNestedCollection() async throws {
    let (inbox, _) = try makeInbox()
    let (store, _) = try makeStore()
    let names = ["a.pdf", "b.pdf", "c.pdf"]
    let request = ShareRequest.fixture(
        entries: names.map { .fixture(type: .document, url: nil, title: $0, fileName: $0) },
        collection: .root, newCollectionName: "Share 2026-10-31 21:44",
        tags: ["t"], note: "n", favorite: true)
    var files: [String: URL] = [:]
    for name in names { files[name] = try tempFile(named: name, bytes: 4) }
    try inbox.enqueue(request, files: files)
    let report = await importer(inbox, store).importAll()
    let collection = CollectionPath(components: ["Share 2026-10-31 21-44"])
    #expect(try await store.collections().contains(collection))
    let items = try await store.listItems().filter { $0.id.collection == collection }
    #expect(items.count == 3 && report.imported.count == 3)
    #expect(items.allSatisfy { $0.tags == ["t"] && $0.note == "n" && $0.favorite && $0.file != nil })
}

@Test func importReshareUpdatesAndMovesExisting() async throws {
    let (inbox, _) = try makeInbox()
    let (store, _) = try makeStore()
    let existing = try await store.create(.fixture(highlights: ["h1"]), in: .unsorted)
    let billa = try await store.createCollection(named: "Billa", in: .root)
    try inbox.enqueue(
        .fixture(
            entries: [.fixture(highlight: "h2")], existingItem: existing.id,
            edits: SheetEdits(collection: billa)),
        files: [:])
    let report = await importer(inbox, store).importAll()
    #expect(report.imported == [ItemID(relativePath: "Billa/T.md")])
    let all = try await store.listItems()
    #expect(all.count == 1 && all[0].highlights == ["h1", "h2"])
    #expect(try inbox.pending().isEmpty)
}

@Test func importReshareOfDeletedItemFallsBackToCreate() async throws {
    let (inbox, _) = try makeInbox()
    let (store, _) = try makeStore()
    try inbox.enqueue(
        .fixture(existingItem: ItemID(relativePath: "Unsorted/Gone.md")), files: [:])
    let report = await importer(inbox, store).importAll()
    #expect(report.imported == [ItemID(relativePath: "Unsorted/T.md")])
    #expect(try await store.listItems().count == 1)
}

@Test func importLeavesInboxWhenStoreUnavailable() async throws {
    let (inbox, _) = try makeInbox()
    let (real, _) = try makeStore()
    let request = ShareRequest.fixture()
    try inbox.enqueue(request, files: [:])
    let report = await importer(inbox, UnavailableStore(base: real)).importAll()
    #expect(report.failed == 1 && report.imported.isEmpty)
    #expect(try inbox.pending().map(\.request.id) == [request.id])
}

@Test func unavailableStopsProcessingFurtherRequests() async throws {
    let (inbox, _) = try makeInbox()
    let (real, _) = try makeStore()
    try inbox.enqueue(.fixture(created: Date(timeIntervalSince1970: 1)), files: [:])
    try inbox.enqueue(.fixture(created: Date(timeIntervalSince1970: 2)), files: [:])
    let report = await importer(inbox, UnavailableStore(base: real)).importAll()
    #expect(report.failed == 1)
    #expect(try inbox.pending().count == 2)
}

@Test func webLinksArePendingCapture() async throws {
    let (inbox, _) = try makeInbox()
    let (store, _) = try makeStore()
    try inbox.enqueue(.fixture(entries: [.fixture(title: "Link")]), files: [:])
    let file = try tempFile(named: "f.pdf", bytes: 4)
    try inbox.enqueue(
        .fixture(
            created: Date(timeIntervalSince1970: 9999999999),
            entries: [.fixture(type: .document, url: nil, title: "File", fileName: "f.pdf")]),
        files: ["f.pdf": file])
    let report = await importer(inbox, store).importAll()
    #expect(report.imported.count == 2)
    let items = try await store.listItems()
    #expect(items.first { $0.title == "Link" }?.capture == .pending)
    #expect(items.first { $0.title == "File" }?.capture == nil)
}
