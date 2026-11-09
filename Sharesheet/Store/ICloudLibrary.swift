import Foundation
import SharesheetCore

/// Resolves the iCloud library root once and caches the folder store on it. Placeholders met while
/// scanning are asked to download.
actor ICloudLibrary {
    private let locate: @Sendable () async -> URL?
    private var store: FolderItemStore?
    /// Shared by callers arriving while the root is being located, so they all get the same store.
    private var resolving: Task<FolderItemStore?, Never>?

    init(locate: @escaping @Sendable () async -> URL? = { await ICloudLocator.libraryRoot() }) {
        self.locate = locate
    }

    /// Without a library the next call asks again.
    func resolve() async -> (any ItemStore)? {
        if let store { return store }
        let task: Task<FolderItemStore?, Never>
        if let resolving {
            task = resolving
        } else {
            let locate = locate
            task = Task {
                guard let root = await locate() else { return nil }
                return FolderItemStore(root: root) { url in
                    try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                }
            }
            resolving = task
        }
        let resolved = await task.value
        if resolving == task { resolving = nil }
        if let resolved, store == nil { store = resolved }
        return store
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
    func create(
        _ draft: ItemDraft, in collection: CollectionPath, willWrite: @Sendable (ItemID) throws -> Void
    ) async throws -> Item {
        try await store().create(draft, in: collection, willWrite: willWrite)
    }
    func update(_ item: Item) async throws -> Item { try await store().update(item) }
    func modify(_ id: ItemID, _ transform: @Sendable (inout Item) throws -> Void) async throws -> Item {
        try await store().modify(id, transform)
    }
    func move(_ id: ItemID, to collection: CollectionPath) async throws -> Item {
        try await store().move(id, to: collection)
    }
    func delete(_ id: ItemID) async throws { try await store().delete(id) }
    func addAttachment(from source: URL, preferredName: String, in collection: CollectionPath) async throws -> String {
        try await store().addAttachment(from: source, preferredName: preferredName, in: collection)
    }
    func attachmentURL(_ relativePath: String) async throws -> URL { try await store().attachmentURL(relativePath) }
    func consolidateAttachments() async throws -> [AttachmentMove] { try await store().consolidateAttachments() }
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
