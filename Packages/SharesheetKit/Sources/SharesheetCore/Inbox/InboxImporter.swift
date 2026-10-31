import Foundation

public struct ImportReport: Equatable, Sendable {
    public var imported: [ItemID]
    public var failed: Int

    public init(imported: [ItemID] = [], failed: Int = 0) {
        self.imported = imported
        self.failed = failed
    }
}

/// Moves pending inbox requests into the store. A request leaves the inbox only after every entry is written.
public struct InboxImporter: Sendable {
    private let inbox: Inbox
    private let store: any ItemStore

    public init(inbox: Inbox, store: any ItemStore) {
        self.inbox = inbox
        self.store = store
    }

    public func importAll() async -> ImportReport {
        var report = ImportReport()
        guard let pending = try? inbox.pending() else { return report }
        for (request, directory) in pending {
            do {
                report.imported += try await importRequest(request, directory: directory)
                try? inbox.remove(request.id)
            } catch StoreError.unavailable {
                report.failed += 1
                break
            } catch {
                report.failed += 1
            }
        }
        return report
    }

    private func importRequest(_ request: ShareRequest, directory: URL) async throws -> [ItemID] {
        if let existing = request.existingItem, let entry = request.entries.first {
            do {
                return [try await reshare(request, entry: entry, existing: existing)]
            } catch StoreError.notFound {
                // The item was deleted meanwhile; import it as new.
            }
        }
        var target = request.collection
        if request.entries.count > 1 {
            target = try await store.createCollection(
                named: request.newCollectionName ?? "Share", in: request.collection)
        }
        var ids: [ItemID] = []
        for entry in request.entries {
            ids.append(try await create(entry, request: request, directory: directory, in: target))
        }
        return ids
    }

    private func reshare(_ request: ShareRequest, entry: ShareEntry, existing: ItemID) async throws -> ItemID {
        let edits = request.edits ?? SheetEdits()
        let current = try await store.item(existing)
        var item = try await store.update(current.applying(edits, highlight: entry.highlight))
        if let collection = edits.collection, collection != item.id.collection {
            item = try await store.move(item.id, to: collection)
        }
        return item.id
    }

    private func create(
        _ entry: ShareEntry, request: ShareRequest, directory: URL, in collection: CollectionPath
    ) async throws -> ItemID {
        let draft = ItemDraft(
            type: entry.type, url: entry.url, title: entry.title, description: entry.description,
            tags: request.tags, favorite: request.favorite, note: request.note,
            content: entry.content, highlights: entry.highlight.map { [$0] } ?? [],
            created: request.created,
            fileSource: entry.fileName.map { directory.appending(path: $0) },
            previewImageSource: entry.previewImageName.map { directory.appending(path: $0) })
        var item = try await store.create(draft, in: collection)
        if entry.url != nil, entry.type != .text {
            item.capture = .pending
            item = try await store.update(item)
        }
        return item.id
    }
}
