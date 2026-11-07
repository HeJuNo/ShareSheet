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

@Test func multiEntryRetryResumesWithoutDuplicates() async throws {
    let (inbox, _) = try makeInbox()
    let (real, _) = try makeStore()
    let names = ["a.pdf", "b.pdf", "c.pdf"]
    var files: [String: URL] = [:]
    for name in names { files[name] = try tempFile(named: name, bytes: 4) }
    try inbox.enqueue(
        .fixture(
            entries: names.map { .fixture(type: .document, url: nil, title: $0, fileName: $0) },
            collection: .root, newCollectionName: "Share"),
        files: files)
    let store = FlakyStore(base: real, failingCall: 2)
    let first = await importer(inbox, store).importAll()
    #expect(first.failed == 1 && first.imported.count == 1)
    let second = await importer(inbox, store).importAll()
    #expect(second.failed == 0 && second.imported.count == 2)
    let collections = try await real.collections().filter { $0 != .unsorted }
    #expect(collections == [CollectionPath(components: ["Share"])])
    #expect(try await real.listItems().count == 3)
    #expect(try inbox.pending().isEmpty)
}

@Test func linkIsCreatedPendingInOneWrite() async throws {
    let (inbox, _) = try makeInbox()
    let (store, _) = try makeStore()
    try inbox.enqueue(.fixture(), files: [:])
    _ = await importer(inbox, store).importAll()
    #expect(try await store.listItems().map(\.capture) == [.pending])
}

@Test func failedInboxRemovalDoesNotReimport() async throws {
    let (inbox, _) = try makeInbox()
    let (store, _) = try makeStore()
    try inbox.enqueue(.fixture(), files: [:])
    struct RemovalFailed: Error {}
    let failingRemoval = InboxImporter(inbox: inbox, store: store, now: { Date() }, remove: { _ in throw RemovalFailed() })
    let first = await failingRemoval.importAll()
    #expect(first.imported.count == 1 && first.cleanupFailed == 1)
    let second = await importer(inbox, store).importAll()
    #expect(second.imported.isEmpty && second.cleanupFailed == 0)
    #expect(try await store.listItems().count == 1)
    #expect(try inbox.pending().isEmpty)
}

@Test func corruptRequestIsCountedAndLeftUntouched() async throws {
    let (inbox, root) = try makeInbox()
    let (store, _) = try makeStore()
    let dir = root.appending(path: "bad")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("{nope".utf8).write(to: dir.appending(path: "request.json"))
    let report = await importer(inbox, store).importAll()
    #expect(report.unreadable == 1)
    #expect(FileManager.default.fileExists(atPath: dir.appending(path: "request.json").path))
}

@Test func unreadableInboxRootCountsAsFailed() async throws {
    let file = try tempFile(named: "notadir", bytes: 1)
    let (store, _) = try makeStore()
    let report = await importer(Inbox(root: file), store).importAll()
    #expect(report.failed >= 1)
}

@Test func multiEntryRequestWithExistingItemIsNormalShare() async throws {
    let (inbox, _) = try makeInbox()
    let (store, _) = try makeStore()
    let existing = try await store.create(.fixture(title: "Old"), in: .unsorted)
    try inbox.enqueue(
        .fixture(
            entries: [.fixture(title: "A"), .fixture(title: "B")], collection: .root,
            newCollectionName: "S", existingItem: existing.id),
        files: [:])
    let report = await importer(inbox, store).importAll()
    #expect(report.imported.count == 2)
    #expect(try await store.listItems().count == 3)
}

@Test func reshareFailureDoesNotFallBackToCreate() async throws {
    let (inbox, _) = try makeInbox()
    let (real, _) = try makeStore()
    let existing = try await real.create(.fixture(), in: .unsorted)
    try inbox.enqueue(.fixture(existingItem: existing.id, edits: SheetEdits(note: "n")), files: [:])
    let store = FlakyStore(base: real, failingCall: 0)
    store.updateFails = true
    let report = await importer(inbox, store).importAll()
    #expect(report.failed == 1 && report.imported.isEmpty)
    #expect(try await real.listItems().count == 1)
    #expect(try inbox.pending().count == 1)
}

@Test func fileEntriesAreNeverPendingCapture() async throws {
    let (inbox, _) = try makeInbox()
    let (store, _) = try makeStore()
    let file = try tempFile(named: "f.pdf", bytes: 4)
    try inbox.enqueue(.fixture(entries: [.fixture(type: .document, fileName: "f.pdf")]), files: ["f.pdf": file])
    _ = await importer(inbox, store).importAll()
    #expect(try await store.listItems().first?.capture == nil)
}

@Test func enqueueRejectsUnsafeFileNames() throws {
    let (inbox, _) = try makeInbox()
    let file = try tempFile(named: "x", bytes: 1)
    for name in ["request.json", "progress.json", "a/b", "..", "../x", ""] {
        #expect(throws: InboxError.self) { try inbox.enqueue(.fixture(), files: [name: file]) }
    }
}

@Test func newShareOfKnownURLMergesInsteadOfCreating() async throws {
    let (inbox, _) = try makeInbox()
    let (store, _) = try makeStore()
    let billa = try await store.createCollection(named: "Billa", in: .root)
    let existing = try await store.create(
        .fixture(url: URL(string: "https://a.b/p")!, title: "Kept", tags: ["a"], highlights: ["h1"]), in: billa)
    try inbox.enqueue(
        .fixture(
            entries: [.fixture(type: .video, url: URL(string: "https://a.b/p?utm_source=x")!, title: "New", highlight: "h2")],
            collection: .unsorted, tags: ["a", "b"], note: "fresh", favorite: true),
        files: [:])
    let report = await importer(inbox, store).importAll()
    #expect(report.imported == [existing.id] && report.failed == 0)
    let all = try await store.listItems()
    #expect(all.count == 1)
    let item = all[0]
    #expect(item.id == existing.id && item.title == "Kept" && item.type == .link)
    #expect(item.highlights == ["h1", "h2"] && item.tags == ["a", "b"])
    #expect(item.note == "fresh" && item.favorite)
    #expect(try inbox.pending().isEmpty)
}

@Test func mergeKeepsExistingNoteAndFavoriteAndDedupesHighlight() async throws {
    let (inbox, _) = try makeInbox()
    let (store, _) = try makeStore()
    _ = try await store.create(.fixture(favorite: true, note: "old", highlights: ["h1"]), in: .unsorted)
    try inbox.enqueue(.fixture(entries: [.fixture(highlight: "h1")], note: "new", favorite: false), files: [:])
    _ = await importer(inbox, store).importAll()
    let all = try await store.listItems()
    #expect(all.count == 1 && all[0].note == "old" && all[0].favorite && all[0].highlights == ["h1"])
}

@Test func mergeDoesNotAddATagThatDiffersOnlyInCase() async throws {
    let (inbox, _) = try makeInbox()
    let (store, _) = try makeStore()
    _ = try await store.create(.fixture(tags: ["Rechnung"]), in: .unsorted)
    try inbox.enqueue(.fixture(entries: [.fixture(highlight: "h")], tags: ["rechnung", "neu"]), files: [:])
    _ = await importer(inbox, store).importAll()
    #expect(try await store.listItems().map(\.tags) == [["Rechnung", "neu"]])
}

@Test func onlyHTTPLinksArePendingCapture() async throws {
    let (inbox, _) = try makeInbox()
    let (store, _) = try makeStore()
    let urls = ["ftp://a.b/x", "mailto:a@b.c", "file:///etc/hosts", "HTTPS://a.b/up", "http://a.b/plain"]
    for (index, url) in urls.enumerated() {
        try inbox.enqueue(
            .fixture(created: Date(timeIntervalSince1970: Double(index)), entries: [.fixture(url: URL(string: url)!, title: "L\(index)")]),
            files: [:])
    }
    _ = await importer(inbox, store).importAll()
    let byTitle = Dictionary(uniqueKeysWithValues: try await store.listItems().map { ($0.title, $0.capture) })
    #expect(byTitle == ["L0": nil, "L1": nil, "L2": nil, "L3": .pending, "L4": .pending])
}
