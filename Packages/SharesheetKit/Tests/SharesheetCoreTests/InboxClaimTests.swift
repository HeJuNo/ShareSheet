import Testing
import Foundation
@testable import SharesheetCore

private struct Crash: Error {}

/// Wraps a store; `create` writes the item, then throws as if the process died before the importer saved progress.
private struct CrashAfterCreateStore: ItemStore {
    let base: any ItemStore
    func listItems() async throws -> [Item] { try await base.listItems() }
    func item(_ id: ItemID) async throws -> Item { try await base.item(id) }
    func findItem(url: URL) async throws -> Item? { try await base.findItem(url: url) }
    func create(
        _ draft: ItemDraft, in collection: CollectionPath, willWrite: @Sendable (ItemID) throws -> Void
    ) async throws -> Item {
        _ = try await base.create(draft, in: collection, willWrite: willWrite)
        throw Crash()
    }
    func update(_ item: Item) async throws -> Item { try await base.update(item) }
    func modify(_ id: ItemID, _ transform: @Sendable (inout Item) throws -> Void) async throws -> Item {
        try await base.modify(id, transform)
    }
    func move(_ id: ItemID, to collection: CollectionPath) async throws -> Item {
        try await base.move(id, to: collection)
    }
    func delete(_ id: ItemID) async throws { try await base.delete(id) }
    func addAttachment(from source: URL, preferredName: String) async throws -> String {
        try await base.addAttachment(from: source, preferredName: preferredName)
    }
    func attachmentURL(_ relativePath: String) async throws -> URL { try await base.attachmentURL(relativePath) }
    func collections() async throws -> [CollectionPath] { try await base.collections() }
    func createCollection(named name: String, in parent: CollectionPath) async throws -> CollectionPath {
        try await base.createCollection(named: name, in: parent)
    }
    func deleteCollection(_ path: CollectionPath, moveItemsTo destination: CollectionPath?) async throws {
        try await base.deleteCollection(path, moveItemsTo: destination)
    }
    func changes() -> AsyncStream<Void> { base.changes() }
}

@Test func concurrentImportersImportEachEntryExactlyOnce() async throws {
    for _ in 0..<15 {
        let inboxRoot = try makeTempDirectory()
        let libraryRoot = try makeTempDirectory()
        let inbox = Inbox(root: inboxRoot)
        // App and extension: separate processes, separate store instances on one library.
        let app = InboxImporter(inbox: inbox, store: FolderItemStore(root: libraryRoot))
        let share = InboxImporter(inbox: inbox, store: FolderItemStore(root: libraryRoot))
        let names = ["a.pdf", "b.pdf", "c.pdf"]
        var files: [String: URL] = [:]
        for name in names { files[name] = try tempFile(named: name, bytes: 4) }
        try inbox.enqueue(
            .fixture(
                entries: names.map { .fixture(type: .document, url: nil, title: $0, fileName: $0) },
                collection: .root, newCollectionName: "Share"),
            files: files)
        for index in 0..<3 {
            try inbox.enqueue(
                .fixture(
                    created: Date(timeIntervalSince1970: Double(index)),
                    entries: [.fixture(type: .text, url: nil, title: "Note \(index)", content: "c")]),
                files: [:])
        }
        let reports = await withTaskGroup(of: ImportReport.self) { group in
            group.addTask { await app.importAll() }
            group.addTask { await share.importAll() }
            return await group.reduce(into: [ImportReport]()) { $0.append($1) }
        }
        let store = FolderItemStore(root: libraryRoot)
        let items = try await store.listItems()
        #expect(items.count == 6)
        #expect(Set(items.map(\.title)).count == 6)
        #expect(try await store.collections().filter { $0 != .unsorted }.count == 1)
        #expect(reports.map(\.imported.count).reduce(0, +) == 6)
        #expect(try inbox.pending().isEmpty)
    }
}

@Test func importRequestTakesOnlyThatRequest() async throws {
    let inbox = Inbox(root: try makeTempDirectory())
    let (store, _) = try makeStore()
    let other = ShareRequest.fixture(entries: [.fixture(type: .text, url: nil, title: "Other", content: "c")])
    let mine = ShareRequest.fixture(entries: [.fixture(type: .text, url: nil, title: "Mine", content: "c")])
    try inbox.enqueue(other, files: [:])
    try inbox.enqueue(mine, files: [:])
    let report = await InboxImporter(inbox: inbox, store: store).importRequest(mine.id)
    #expect(report.imported.count == 1)
    #expect(try await store.listItems().map(\.title) == ["Mine"])
    #expect(try inbox.pending().map(\.request.id) == [other.id])
}

@Test func claimedRequestIsSkippedUntilTheClaimIsStale() async throws {
    let inbox = Inbox(root: try makeTempDirectory())
    let (store, _) = try makeStore()
    let request = ShareRequest.fixture()
    try inbox.enqueue(request, files: [:])
    let start = Date(timeIntervalSince1970: 1_000_000)
    let directory = try #require(try inbox.pending(now: start).first?.directory)
    #expect(inbox.claim(directory, now: start) != nil)
    #expect(try inbox.pending(now: start.addingTimeInterval(60)).isEmpty)

    let early = await InboxImporter(inbox: inbox, store: store, now: { start.addingTimeInterval(60) }).importAll()
    #expect(early.imported.isEmpty && early.failed == 0)

    let late = await InboxImporter(inbox: inbox, store: store, now: { start.addingTimeInterval(601) }).importAll()
    #expect(late.imported.count == 1)
    #expect(try inbox.pending(now: start.addingTimeInterval(601)).isEmpty)
}

@Test func failedImportReleasesTheClaim() async throws {
    let inbox = Inbox(root: try makeTempDirectory())
    let (real, _) = try makeStore()
    let request = ShareRequest.fixture()
    try inbox.enqueue(request, files: [:])
    _ = await InboxImporter(inbox: inbox, store: UnavailableStore(base: real)).importAll()
    let pending = try inbox.pending()
    #expect(pending.map(\.directory.lastPathComponent) == [request.id.uuidString])
}

@Test func retryAfterCrashBetweenWriteAndProgressCreatesNoDuplicate() async throws {
    let inbox = Inbox(root: try makeTempDirectory())
    let (real, _) = try makeStore()
    try inbox.enqueue(.fixture(entries: [.fixture(type: .text, url: nil, title: "Once", content: "c")]), files: [:])
    let first = await InboxImporter(inbox: inbox, store: CrashAfterCreateStore(base: real)).importAll()
    #expect(first.failed == 1)
    #expect(try await real.listItems().count == 1)
    let second = await InboxImporter(inbox: inbox, store: real).importAll()
    #expect(second.failed == 0)
    #expect(try await real.listItems().map(\.title) == ["Once"])
    #expect(second.imported == [ItemID(relativePath: "Unsorted/Once.md")])
    #expect(try inbox.pending().isEmpty)
}

@Test func retryAfterCrashOfALinkCreatesNoDuplicate() async throws {
    let inbox = Inbox(root: try makeTempDirectory())
    let (real, _) = try makeStore()
    // Another item with the same URL is already in the library under a different title.
    try inbox.enqueue(.fixture(entries: [.fixture(url: URL(string: "https://x.y/page")!, title: "Page")]), files: [:])
    _ = await InboxImporter(inbox: inbox, store: CrashAfterCreateStore(base: real)).importAll()
    let second = await InboxImporter(inbox: inbox, store: real).importAll()
    #expect(second.failed == 0)
    #expect(try await real.listItems().count == 1)
}
