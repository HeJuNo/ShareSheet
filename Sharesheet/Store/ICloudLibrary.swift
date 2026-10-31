import Foundation
import SharesheetCore

/// Resolves the iCloud library root once and caches the folder store on it. Placeholders met while
/// scanning are asked to download.
actor ICloudLibrary {
    private var store: FolderItemStore?

    func resolve() async -> (any ItemStore)? {
        if let store { return store }
        guard let root = await ICloudLocator.libraryRoot() else { return nil }
        let resolved = FolderItemStore(root: root) { url in
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
        store = resolved
        return resolved
    }
}

/// An `ItemStore` that resolves the iCloud library on first use, so the capture runner can be built
/// before iCloud answers. Every call throws `StoreError.unavailable` while there is no library.
struct ResolvingItemStore: ItemStore {
    let library: ICloudLibrary

    private func store() async throws -> any ItemStore {
        guard let store = await library.resolve() else { throw StoreError.unavailable }
        return store
    }

    func listItems() async throws -> [Item] { try await store().listItems() }
    func item(_ id: ItemID) async throws -> Item { try await store().item(id) }
    func findItem(url: URL) async throws -> Item? { try await store().findItem(url: url) }
    func create(_ draft: ItemDraft, in collection: CollectionPath) async throws -> Item {
        try await store().create(draft, in: collection)
    }
    func update(_ item: Item) async throws -> Item { try await store().update(item) }
    func move(_ id: ItemID, to collection: CollectionPath) async throws -> Item {
        try await store().move(id, to: collection)
    }
    func delete(_ id: ItemID) async throws { try await store().delete(id) }
    func addAttachment(from source: URL, preferredName: String) async throws -> String {
        try await store().addAttachment(from: source, preferredName: preferredName)
    }
    func attachmentURL(_ relativePath: String) async throws -> URL { try await store().attachmentURL(relativePath) }
    func collections() async throws -> [CollectionPath] { try await store().collections() }
    func createCollection(named name: String, in parent: CollectionPath) async throws -> CollectionPath {
        try await store().createCollection(named: name, in: parent)
    }
    func deleteCollection(_ path: CollectionPath, moveItemsTo destination: CollectionPath?) async throws {
        try await store().deleteCollection(path, moveItemsTo: destination)
    }

    func changes() -> AsyncStream<Void> {
        let library = library
        return AsyncStream { continuation in
            let task = Task {
                if let store = await library.resolve() {
                    for await _ in store.changes() { continuation.yield() }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
