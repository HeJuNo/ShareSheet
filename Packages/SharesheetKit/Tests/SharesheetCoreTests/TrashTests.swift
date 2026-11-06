import Foundation
import Testing
@testable import SharesheetCore

@Suite struct TrashTests {
    private func makeLibrary() throws -> (FolderItemStore, URL) {
        let root = try makeTempDirectory()
        return (FolderItemStore(root: root), root)
    }

    private func create(_ store: FolderItemStore, _ title: String, in collection: CollectionPath = .unsorted) async throws -> Item {
        try await store.create(ItemDraft(type: .text, title: title, content: "x"), in: collection)
    }

    private func stamp(_ root: URL, _ relative: String, _ date: Date) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date], ofItemAtPath: root.appending(path: ".trash/\(relative)").path)
    }

    @Test func deletingMovesTheItemIntoTheTrashWhereItCanBeListed() async throws {
        let (store, root) = try makeLibrary()
        let item = try await create(store, "Rechnung")
        try await store.delete(item.id)
        #expect(try await store.listItems().isEmpty)
        let trashed = try await store.trashedItems()
        #expect(trashed.map(\.title) == ["Rechnung"])
        #expect(abs(try #require(trashed.first).deletedAt.timeIntervalSinceNow) < 5)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: ".trash/\(item.id.relativePath)").path))
    }

    @Test func theTrashFolderNeverShowsUpAsACollectionOrItems() async throws {
        let (store, _) = try makeLibrary()
        try await store.delete(try await create(store, "A").id)
        #expect(try await store.collections().allSatisfy { !$0.relativePath.hasPrefix(".") })
        #expect(try await store.listItems().isEmpty)
    }

    @Test func restoringPutsTheItemBackAndNumbersItWhenTheNameIsTaken() async throws {
        let (store, _) = try makeLibrary()
        let collection = try await store.createCollection(named: "Rechnungen", in: .root)
        let first = try await create(store, "Tesla", in: collection)
        try await store.delete(first.id)
        let again = try await create(store, "Tesla", in: collection)  // same title, same file name
        #expect(again.id == first.id)
        let restored = try await store.restore(try #require(await store.trashedItems().first).id)
        #expect(restored.id != first.id)
        #expect(restored.id.relativePath.hasPrefix("Rechnungen/"))
        #expect(try await store.listItems().count == 2)
        #expect(try await store.trashedItems().isEmpty)
    }

    @Test func restoringBringsTheAttachmentsBackToo() async throws {
        let (store, root) = try makeLibrary()
        let file = try tempFile(named: "scan.pdf", bytes: 16)
        let item = try await store.create(ItemDraft(type: .document, title: "Scan", fileSource: file), in: .unsorted)
        let attachment = try #require(item.file)
        try await store.delete(item.id)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: attachment).path))
        let restored = try await store.restore(try #require(await store.trashedItems().first).id)
        #expect(restored.file == attachment)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: attachment).path))
    }

    @Test func purgingDeletesTheItemAndItsAttachmentForGood() async throws {
        let (store, root) = try makeLibrary()
        let item = try await store.create(ItemDraft(type: .document, title: "Scan", fileSource: try tempFile(named: "a.pdf", bytes: 8)), in: .unsorted)
        let attachment = try #require(item.file)
        try await store.delete(item.id)
        try await store.purge(try #require(await store.trashedItems().first).id)
        #expect(try await store.trashedItems().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".trash/\(attachment)").path))
    }

    @Test func emptyingTheTrashRemovesEverything() async throws {
        let (store, root) = try makeLibrary()
        for title in ["A", "B"] { try await store.delete(try await create(store, title).id) }
        try await store.emptyTrash()
        #expect(try await store.trashedItems().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: ".trash").path).isEmpty)
    }

    @Test func onlyItemsOlderThanTheCutoffAreRemovedAndTheCutoffItselfStays() async throws {
        let (store, root) = try makeLibrary()
        let cutoff = Date(timeIntervalSince1970: 1_700_000_000)
        var names: [String: String] = [:]
        for (title, offset) in [("Alt", -1.0), ("Genau", 0), ("Neu", 1)] {
            let item = try await create(store, title)
            try await store.delete(item.id)
            names[title] = item.id.relativePath
            try stamp(root, item.id.relativePath, cutoff.addingTimeInterval(offset))
        }
        let removed = try await store.purgeTrash(olderThan: cutoff)
        #expect(removed == 1)
        #expect(Set(try await store.trashedItems().map(\.title)) == ["Genau", "Neu"])
    }
}
