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
    case collectionNotEmpty
    case unavailable
}

public protocol Trashing: Sendable {
    func trash(_ url: URL, libraryRoot: URL) throws
}

/// `FileManager.trashItem`, falling back to moving the file into `<root>/.trash/`. Never deletes.
public struct SystemTrash: Trashing {
    public init() {}

    public func trash(_ url: URL, libraryRoot: URL) throws {
        let fm = FileManager.default
        do {
            try fm.trashItem(at: url, resultingItemURL: nil)
        } catch {
            let folder = libraryRoot.appending(path: ".trash", directoryHint: .isDirectory)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let existing = Set((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
            let ext = url.pathExtension
            let stem = url.deletingPathExtension().lastPathComponent
            let name = FileNamer.uniqueName(base: stem, ext: ext, existing: existing)
            try fm.moveItem(at: url, to: folder.appending(path: name))
        }
    }
}
