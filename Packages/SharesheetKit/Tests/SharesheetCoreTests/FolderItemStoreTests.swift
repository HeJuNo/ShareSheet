import Foundation
import Synchronization
import Testing
@testable import SharesheetCore

private func exists(_ root: URL, _ path: String) -> Bool {
    FileManager.default.fileExists(atPath: root.appending(path: path).path)
}

private func mkdir(_ root: URL, _ path: String) throws {
    try FileManager.default.createDirectory(at: root.appending(path: path), withIntermediateDirectories: true)
}

@Test func createWritesMarkdownAndCopiesAttachment() async throws {
    let (store, root) = try makeStore()
    let pdf = try tempFile(named: "Mietvertrag.pdf", bytes: 1024)
    let item = try await store.create(.fixture(type: .document, title: "Mietvertrag", fileSource: pdf), in: .unsorted)
    #expect(item.id.relativePath == "Unsorted/Mietvertrag.md")
    #expect(item.file == "_attachments/Mietvertrag.pdf")
    #expect(exists(root, "_attachments/Mietvertrag.pdf"))
    #expect(try await store.item(item.id) == item)
}

@Test func createTruncatesCreatedAndStoresPreview() async throws {
    let (store, root) = try makeStore()
    let preview = try tempFile(named: "og.png", bytes: 10)
    let created = Date(timeIntervalSince1970: 1_800_000_000.75)
    let item = try await store.create(.fixture(title: "Hello World", created: created, previewImageSource: preview), in: .unsorted)
    #expect(item.created == Date(timeIntervalSince1970: 1_800_000_000))
    #expect(item.image == "_attachments/Hello World-preview.png")
    #expect(item.capture == nil)
    #expect(exists(root, "_attachments/Hello World-preview.png"))
    #expect(try await store.item(item.id) == item)
}

@Test func sameTitleGetsUniqueFile() async throws {
    let (store, _) = try makeStore()
    let a = try await store.create(.fixture(title: "T"), in: .unsorted)
    let b = try await store.create(.fixture(title: "T"), in: .unsorted)
    #expect(a.id.relativePath == "Unsorted/T.md")
    #expect(b.id.relativePath == "Unsorted/T 2.md")
}

@Test func findItemMatchesCleanedURL() async throws {
    let (store, _) = try makeStore()
    _ = try await store.create(.fixture(url: URL(string: "https://pamba.app/")!), in: .unsorted)
    #expect(try await store.findItem(url: URL(string: "https://pamba.app/?twclid=1")!) != nil)
    #expect(try await store.findItem(url: URL(string: "https://other.app/")!) == nil)
}

@Test func updatePersistsChanges() async throws {
    let (store, _) = try makeStore()
    var item = try await store.create(.fixture(), in: .unsorted)
    item.favorite = true
    item.note = "hi"
    let updated = try await store.update(item)
    #expect(try await store.item(updated.id) == updated)
    #expect(updated.favorite)
}

@Test func moveRelocatesMarkdownOnly() async throws {
    let (store, root) = try makeStore()
    let pdf = try tempFile(named: "x.pdf", bytes: 5)
    let item = try await store.create(.fixture(type: .document, fileSource: pdf), in: .unsorted)
    let moved = try await store.move(item.id, to: CollectionPath(components: ["Billa"]))
    #expect(moved.id.relativePath == "Billa/T.md")
    #expect(moved.file == item.file)
    #expect(exists(root, "Billa/T.md"))
    #expect(!exists(root, "Unsorted/T.md"))
    #expect(exists(root, "_attachments/x.pdf"))
    #expect(try await store.item(moved.id) == moved)
}

@Test func deleteTrashesUnsharedAttachmentsOnly() async throws {
    let trash = RecordingTrash()
    let (store, root) = try makeStore(trash: trash)
    let img = try tempFile(named: "x.jpg", bytes: 5)
    let shared = try await store.addAttachment(from: img, preferredName: "x.jpg")
    var first = try await store.create(.fixture(title: "A"), in: .unsorted)
    var second = try await store.create(.fixture(title: "B"), in: .unsorted)
    first.image = shared
    second.image = shared
    first = try await store.update(first)
    second = try await store.update(second)

    try await store.delete(first.id)
    #expect(trash.trashed.map(\.lastPathComponent) == ["A.md"])
    #expect(exists(root, "_attachments/x.jpg"))

    try await store.delete(second.id)
    #expect(trash.trashed.map(\.lastPathComponent) == ["A.md", "B.md", "x.jpg"])
    #expect(!exists(root, "_attachments/x.jpg"))
}

@Test func collectionsAreNestedAndSkipReserved() async throws {
    let (store, root) = try makeStore()
    for dir in ["Billa/2026", "_attachments", ".trash"] { try mkdir(root, dir) }
    let expected = [
        CollectionPath(components: ["Billa"]),
        CollectionPath(components: ["Billa", "2026"]),
        .unsorted,
    ]
    #expect(try await store.collections() == expected)
}

@Test func createCollectionNestsAndUniquifies() async throws {
    let (store, root) = try makeStore()
    let billa = try await store.createCollection(named: "Billa", in: .root)
    let year = try await store.createCollection(named: "2026", in: billa)
    #expect(year.relativePath == "Billa/2026")
    #expect(exists(root, "Billa/2026"))
    #expect(try await store.createCollection(named: "Billa", in: .root).relativePath == "Billa 2")
}

@Test func deleteNonEmptyCollectionThrowsUnlessMoved() async throws {
    let (store, root) = try makeStore()
    let billa = CollectionPath(components: ["Billa"])
    let item = try await store.create(.fixture(), in: billa)
    await #expect(throws: StoreError.collectionNotEmpty) {
        try await store.deleteCollection(billa, moveItemsTo: nil)
    }
    #expect(exists(root, item.id.relativePath))
    try await store.deleteCollection(billa, moveItemsTo: .unsorted)
    #expect(exists(root, "Unsorted/T.md"))
    #expect(!exists(root, "Billa"))
}

@Test func deleteEmptyCollectionWorks() async throws {
    let (store, root) = try makeStore()
    let empty = try await store.createCollection(named: "Empty", in: .root)
    try await store.deleteCollection(empty, moveItemsTo: nil)
    #expect(!exists(root, "Empty"))
}

@Test func placeholderFilesAreReportedNotParsed() async throws {
    let seen = Mutex<[URL]>([])
    let (store, root) = try makeStore(onPlaceholder: { url in seen.withLock { $0.append(url) } })
    try mkdir(root, "Unsorted")
    try Data().write(to: root.appending(path: "Unsorted/.Foo.md.icloud"))
    #expect(try await store.listItems().isEmpty)
    #expect(seen.withLock { $0.map(\.lastPathComponent) } == [".Foo.md.icloud"])
}

@Test func unparseableMarkdownIsSkippedNotFatal() async throws {
    let (store, root) = try makeStore()
    let good = try await store.create(.fixture(), in: .unsorted)
    try Data([0xFF, 0xFE, 0x00, 0x01]).write(to: root.appending(path: "Unsorted/garbage.md"))
    #expect(try await store.listItems() == [good])
}

@Test func missingItemThrowsNotFound() async throws {
    let (store, _) = try makeStore()
    await #expect(throws: StoreError.notFound("Unsorted/Nope.md")) {
        _ = try await store.item(ItemID(relativePath: "Unsorted/Nope.md"))
    }
}
