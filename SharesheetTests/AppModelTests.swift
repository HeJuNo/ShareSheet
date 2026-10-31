import Foundation
import Testing
@testable import Sharesheet
import SharesheetCore

@MainActor
private struct ModelEnv {
    let base: URL
    let libraryRoot: URL
    let inbox: Inbox
    let index: LibraryIndex
    let store: FolderItemStore

    init() throws {
        base = FileManager.default.temporaryDirectory.appending(path: "AppModelTests-\(UUID().uuidString)")
        libraryRoot = base.appending(path: "Library", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: libraryRoot.appending(path: "Unsorted"), withIntermediateDirectories: true)
        inbox = Inbox(root: base.appending(path: "Inbox", directoryHint: .isDirectory))
        index = try LibraryIndex(path: base.appending(path: "index.sqlite"))
        store = FolderItemStore(root: libraryRoot)
    }

    func model(iCloud: Bool = true, temporaryRoot: URL? = nil) -> AppModel {
        let store = self.store
        return AppModel(
            storeFactory: { iCloud ? store : nil }, index: index, inbox: inbox, runner: nil,
            extensionTemporaryRoot: temporaryRoot)
    }

    func enqueueText(_ title: String) throws {
        let request = ShareRequest(
            entries: [ShareEntry(type: .text, title: title, content: "Body of \(title)")], collection: .unsorted)
        try inbox.enqueue(request, files: [:])
    }
}

@MainActor
struct AppModelTests {
    @Test func refreshImportsInboxAndIndexes() async throws {
        let env = try ModelEnv()
        try env.enqueueText("Shopping list")
        let model = env.model()

        await model.refresh()

        #expect(model.isICloudAvailable)
        #expect(model.counts.all == 1)
        #expect(model.counts.unsorted == 1)
        #expect(try env.inbox.pending().isEmpty)
        #expect(model.items(LibraryQuery(text: "shopping", scope: .all)).map(\.title) == ["Shopping list"])
        #expect(model.collections.contains(.unsorted))
    }

    @Test func refreshWithoutICloudKeepsInbox() async throws {
        let env = try ModelEnv()
        try env.enqueueText("Shopping list")
        let model = env.model(iCloud: false)

        await model.refresh()

        #expect(!model.isICloudAvailable)
        #expect(model.iCloudState == .unavailable)
        #expect(try env.inbox.pending().count == 1)
        #expect(model.counts.all == 0)
    }

    @Test func refreshPicksUpExternalMove() async throws {
        let env = try ModelEnv()
        let billa = CollectionPath(components: ["Billa"])
        let item = try await env.store.create(ItemDraft(type: .text, title: "Receipt", tags: ["groceries"]), in: .unsorted)
        _ = try await env.store.createCollection(named: "Billa", in: .root)
        let model = env.model()
        await model.refresh()
        #expect(model.items(LibraryQuery(scope: .collection(billa))).isEmpty)

        let source = env.libraryRoot.appending(path: item.id.relativePath)
        try FileManager.default.moveItem(at: source, to: env.libraryRoot.appending(path: "Billa/Receipt.md"))
        await model.refresh()

        #expect(model.items(LibraryQuery(scope: .collection(billa))).map(\.title) == ["Receipt"])
        #expect(model.counts.unsorted == 0)
        #expect(model.counts.byCollection[billa] == 1)
        #expect(model.collections.contains(billa))
        #expect(model.tags == ["groceries"])
    }

    @Test func concurrentRefreshesCoalesce() async throws {
        let env = try ModelEnv()
        try env.enqueueText("First")
        let model = env.model()

        async let one: Void = model.refresh()
        async let two: Void = model.refresh()
        _ = await (one, two)

        #expect(model.counts.all == 1)
        #expect(try env.inbox.pending().isEmpty)
    }

    @Test func refreshSweepsStaleExtensionTemporaryFiles() async throws {
        let env = try ModelEnv()
        let tmp = env.base.appending(path: "Tmp", directoryHint: .isDirectory)
        let stale = tmp.appending(path: "stale", directoryHint: .isDirectory)
        let fresh = tmp.appending(path: "fresh", directoryHint: .isDirectory)
        for folder in [stale, fresh] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-2 * 3600)], ofItemAtPath: stale.path)
        let model = env.model(temporaryRoot: tmp)

        await model.refresh()

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test func faviconIsLookedUpByFullHost() async throws {
        let env = try ModelEnv()
        _ = try await env.store.create(
            ItemDraft(type: .link, url: URL(string: "https://www.example.com/a")!, title: "Example"), in: .unsorted)
        try env.index.setFavicon(Data([1, 2, 3]), host: "www.example.com")
        let model = env.model()
        await model.refresh()

        let item = try #require(model.items(LibraryQuery(scope: .all)).first)
        #expect(model.favicon(for: item) == Data([1, 2, 3]))
    }

    @Test func deleteRemovesItemAndUpdatesCounts() async throws {
        let env = try ModelEnv()
        _ = try await env.store.create(ItemDraft(type: .text, title: "Old", favorite: true), in: .unsorted)
        let model = env.model()
        await model.refresh()
        let item = try #require(model.items(LibraryQuery(scope: .all)).first)

        try await model.toggleFavorite(item)
        #expect(model.counts.favorites == 0)
        try await model.delete(item)

        #expect(model.counts.all == 0)
        #expect(try await env.store.listItems().isEmpty)
    }

    @Test func iCloudStateIsUnknownUntilTheStoreAnswers() async throws {
        let env = try ModelEnv()
        let model = env.model()
        #expect(model.iCloudState == .unknown)
        #expect(!model.isICloudAvailable)

        await model.refresh()

        #expect(model.iCloudState == .available)
    }

    @Test func deletingAMissingItemThrows() async throws {
        let env = try ModelEnv()
        _ = try await env.store.create(ItemDraft(type: .text, title: "Gone"), in: .unsorted)
        let model = env.model()
        await model.refresh()
        let item = try #require(model.items(LibraryQuery(scope: .all)).first)
        try FileManager.default.removeItem(at: env.libraryRoot.appending(path: item.id.relativePath))

        await #expect(throws: (any Error).self) { try await model.delete(item) }
        await #expect(throws: (any Error).self) { try await model.toggleFavorite(item) }
    }

    @Test func creatingAReservedCollectionThrows() async throws {
        let env = try ModelEnv()
        let model = env.model()
        await model.refresh()

        for name in ["_attachments", ".hidden", "   "] {
            await #expect(throws: (any Error).self) { try await model.createCollection(named: name, in: .root) }
        }
        let created = try await model.createCollection(named: "Billa", in: .root)
        #expect(created == CollectionPath(components: ["Billa"]))
        #expect(model.collections.contains(created))
    }

    @Test func corruptInboxRequestIsCountedAsImportProblem() async throws {
        let env = try ModelEnv()
        let broken = env.base.appending(path: "Inbox/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: broken.appending(path: "request.json"))
        try env.enqueueText("Fine")
        let model = env.model()

        await model.refresh()

        #expect(model.lastImportProblemCount == 1)
        #expect(model.counts.all == 1)
    }

    @Test func pendingCaptureCountComesFromIndex() async throws {
        let env = try ModelEnv()
        _ = try await env.store.create(
            ItemDraft(type: .link, url: URL(string: "https://example.com")!, title: "Page", capture: .pending),
            in: .unsorted)
        _ = try await env.store.create(ItemDraft(type: .text, title: "Note"), in: .unsorted)
        let model = env.model()
        await model.refresh()

        #expect(model.pendingCaptureCount == 1)
    }
}
