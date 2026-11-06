import Foundation

public protocol ItemStore: Sendable {
    func listItems() async throws -> [Item]
    func item(_ id: ItemID) async throws -> Item
    /// Compares `URLCleaner.clean` on both sides.
    func findItem(url: URL) async throws -> Item?
    /// `willWrite` runs with the chosen id right before the file is written; when it throws, nothing is written.
    func create(
        _ draft: ItemDraft, in collection: CollectionPath, willWrite: @Sendable (ItemID) throws -> Void
    ) async throws -> Item
    func update(_ item: Item) async throws -> Item
    /// Reads the item, applies `transform` and writes the result, as one step no other mutation of this store
    /// interleaves with. Writes nothing when `transform` changed nothing; throws `.notFound` when it is gone.
    func modify(_ id: ItemID, _ transform: @Sendable (inout Item) throws -> Void) async throws -> Item
    func move(_ id: ItemID, to collection: CollectionPath) async throws -> Item
    func delete(_ id: ItemID) async throws
    /// Returns the library-relative path, e.g. `_attachments/x.png`.
    func addAttachment(from source: URL, preferredName: String) async throws -> String
    func attachmentURL(_ relativePath: String) async throws -> URL
    /// Sorted, nested included, reserved folders excluded, always contains `.unsorted`.
    func collections() async throws -> [CollectionPath]
    func createCollection(named name: String, in parent: CollectionPath) async throws -> CollectionPath
    func deleteCollection(_ path: CollectionPath, moveItemsTo destination: CollectionPath?) async throws
    func changes() -> AsyncStream<Void>
}

extension ItemStore {
    public func create(_ draft: ItemDraft, in collection: CollectionPath) async throws -> Item {
        try await create(draft, in: collection, willWrite: { _ in })
    }
}

public enum StoreError: Error, Equatable {
    case notFound(String)
    /// The file is in iCloud but not on this device yet; its download has been requested.
    case downloading(String)
    case collectionNotEmpty
    case unavailable
}

public protocol Trashing: Sendable {
    func trash(_ url: URL, libraryRoot: URL) throws
}

/// Moves a file into `<root>/.trash/`, keeping its library-relative path, and stamps the time of the move on it
/// (and on everything inside a folder). The app shows this folder as its Trash; nothing is deleted here.
public struct LibraryTrash: Trashing {
    public static let folderName = ".trash"

    public init() {}

    public func trash(_ url: URL, libraryRoot: URL) throws {
        let fm = FileManager.default
        let rootPath = libraryRoot.resolvingSymlinksInPath().path
        let path = url.resolvingSymlinksInPath().path
        let relative = path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : url.lastPathComponent
        let target = libraryRoot.appending(path: Self.folderName).appending(path: relative)
        let folder = target.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let existing = Set((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
        let name = FileNamer.uniqueName(
            base: target.deletingPathExtension().lastPathComponent, ext: target.pathExtension, existing: existing)
        let destination = folder.appending(path: name)
        try fm.moveItem(at: url, to: destination)
        Self.stamp(destination)
    }

    private static func stamp(_ url: URL) {
        let fm = FileManager.default
        let now = Date()
        try? fm.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        for case let inner as URL in fm.enumerator(at: url, includingPropertiesForKeys: nil) ?? NSEnumerator() {
            try? fm.setAttributes([.modificationDate: now], ofItemAtPath: inner.path)
        }
    }
}

/// An item that was deleted: `id` is its path inside the trash folder (the path it had in the library).
public struct TrashedItem: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var deletedAt: Date

    public init(id: String, title: String, deletedAt: Date) {
        self.id = id
        self.title = title
        self.deletedAt = deletedAt
    }
}

public protocol TrashStore: Sendable {
    /// Newest first.
    func trashedItems() async throws -> [TrashedItem]
    /// Puts the item (and its attachments) back where it was; a taken file name gets a number. Returns the item.
    func restore(_ id: String) async throws -> Item
    /// Deletes the item for good, with attachments no other trashed item uses.
    func purge(_ id: String) async throws
    func emptyTrash() async throws
    /// Deletes items deleted before `date` for good; returns how many.
    @discardableResult func purgeTrash(olderThan date: Date) async throws -> Int
}
