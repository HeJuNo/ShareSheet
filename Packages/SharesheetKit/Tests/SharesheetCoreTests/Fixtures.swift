import Foundation
@testable import SharesheetCore

extension Item {
    static func fixture(
        id: String = "Unsorted/T.md",
        type: ItemType = .link,
        url: URL? = URL(string: "https://a.b/")!,
        file: String? = nil,
        title: String = "T",
        description: String? = nil,
        tags: [String] = [],
        favorite: Bool = false,
        created: Date = ISO8601DateFormatter().date(from: "2026-10-31T20:44:00Z")!,
        image: String? = nil,
        screenshot: String? = nil,
        archive: String? = nil,
        capture: CaptureState? = nil,
        content: String? = nil,
        note: String = "",
        highlights: [String] = [],
        extraFrontmatter: [String] = [],
        extraBody: String = ""
    ) -> Item {
        Item(
            id: ItemID(relativePath: id), type: type, url: url, file: file, title: title,
            description: description, tags: tags, favorite: favorite, created: created,
            image: image, screenshot: screenshot, archive: archive, capture: capture,
            note: note, content: content, highlights: highlights,
            extraFrontmatter: extraFrontmatter, extraBody: extraBody)
    }
}

extension ItemDraft {
    static func fixture(
        type: ItemType = .link,
        url: URL? = URL(string: "https://a.b/")!,
        title: String = "T",
        description: String? = nil,
        tags: [String] = [],
        favorite: Bool = false,
        note: String = "",
        content: String? = nil,
        highlights: [String] = [],
        created: Date = ISO8601DateFormatter().date(from: "2026-10-31T20:44:00Z")!,
        fileSource: URL? = nil,
        previewImageSource: URL? = nil
    ) -> ItemDraft {
        ItemDraft(
            type: type, url: url, title: title, description: description, tags: tags,
            favorite: favorite, note: note, content: content, highlights: highlights,
            created: created, fileSource: fileSource, previewImageSource: previewImageSource)
    }
}

/// Records trashed URLs and moves the files into a temp dir instead of deleting them.
final class RecordingTrash: Trashing, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private let bin = FileManager.default.temporaryDirectory.appending(path: "trash-\(UUID().uuidString)")

    var trashed: [URL] { lock.withLock { urls } }

    func trash(_ url: URL, libraryRoot: URL) throws {
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: bin.appending(path: UUID().uuidString + "-" + url.lastPathComponent))
        lock.withLock { urls.append(url) }
    }
}

func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "sharesheet-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func makeStore(
    trash: RecordingTrash = RecordingTrash(),
    onPlaceholder: @escaping @Sendable (URL) -> Void = { _ in }
) throws -> (FolderItemStore, URL) {
    let root = try makeTempDirectory()
    return (FolderItemStore(root: root, trash: trash, onPlaceholder: onPlaceholder), root)
}

func tempFile(named name: String, bytes: Int) throws -> URL {
    let url = try makeTempDirectory().appending(path: name)
    try Data(repeating: 0x41, count: bytes).write(to: url)
    return url
}

extension ShareEntry {
    static func fixture(
        type: ItemType = .link,
        url: URL? = URL(string: "https://a.b/")!,
        title: String = "T",
        description: String? = nil,
        content: String? = nil,
        highlight: String? = nil,
        fileName: String? = nil,
        previewImageName: String? = nil
    ) -> ShareEntry {
        ShareEntry(
            type: type, url: url, title: title, description: description, content: content,
            highlight: highlight, fileName: fileName, previewImageName: previewImageName)
    }
}

extension ShareRequest {
    static func fixture(
        id: UUID = UUID(),
        created: Date = ISO8601DateFormatter().date(from: "2026-10-31T20:44:00Z")!,
        entries: [ShareEntry] = [.fixture()],
        collection: CollectionPath = .unsorted,
        newCollectionName: String? = nil,
        tags: [String] = [],
        note: String = "",
        favorite: Bool = false,
        existingItem: ItemID? = nil,
        edits: SheetEdits? = nil
    ) -> ShareRequest {
        ShareRequest(
            id: id, created: created, entries: entries, collection: collection,
            newCollectionName: newCollectionName, tags: tags, note: note, favorite: favorite,
            existingItem: existingItem, edits: edits)
    }
}

/// A file of the given apparent size with no data written.
func sparseFile(bytes: Int) throws -> URL {
    let url = try makeTempDirectory().appending(path: "sparse.bin")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(bytes))
    try handle.close()
    return url
}

/// Wraps a real store but fails every `create` with `.unavailable`.
struct UnavailableStore: ItemStore {
    let base: any ItemStore
    func listItems() async throws -> [Item] { try await base.listItems() }
    func item(_ id: ItemID) async throws -> Item { try await base.item(id) }
    func findItem(url: URL) async throws -> Item? { try await base.findItem(url: url) }
    func create(_ draft: ItemDraft, in collection: CollectionPath) async throws -> Item {
        throw StoreError.unavailable
    }
    func update(_ item: Item) async throws -> Item { try await base.update(item) }
    func move(_ id: ItemID, to collection: CollectionPath) async throws -> Item {
        try await base.move(id, to: collection)
    }
    func delete(_ id: ItemID) async throws { try await base.delete(id) }
    func addAttachment(from source: URL, preferredName: String) async throws -> String {
        try await base.addAttachment(from: source, preferredName: preferredName)
    }
    func attachmentURL(_ relativePath: String) async throws -> URL {
        try await base.attachmentURL(relativePath)
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
