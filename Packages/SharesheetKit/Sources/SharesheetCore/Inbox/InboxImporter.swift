import Foundation

public struct ImportReport: Equatable, Sendable {
    /// Items written by this run (entries finished by an earlier run are not repeated).
    public var imported: [ItemID]
    /// Requests that could not be imported and stay in the inbox.
    public var failed: Int
    /// Requests whose `request.json` exists but cannot be decoded; left untouched.
    public var unreadable: Int
    /// Requests fully imported whose inbox directory could not be removed.
    public var cleanupFailed: Int

    public init(imported: [ItemID] = [], failed: Int = 0, unreadable: Int = 0, cleanupFailed: Int = 0) {
        self.imported = imported
        self.failed = failed
        self.unreadable = unreadable
        self.cleanupFailed = cleanupFailed
    }
}

/// Moves pending inbox requests into the store. A request leaves the inbox only after every entry is written;
/// progress is persisted per request, so a retry resumes instead of duplicating.
public struct InboxImporter: Sendable {
    static let progressFileName = "progress.json"

    private struct Progress: Codable {
        var collection: CollectionPath?
        var done: [String: String] = [:]
    }

    private let inbox: Inbox
    private let store: any ItemStore

    public init(inbox: Inbox, store: any ItemStore) {
        self.inbox = inbox
        self.store = store
    }

    public func importAll() async -> ImportReport {
        var report = ImportReport()
        let scan: (requests: [(request: ShareRequest, directory: URL)], unreadable: Int)
        do {
            scan = try inbox.scan()
        } catch {
            report.failed = 1
            return report
        }
        report.unreadable = scan.unreadable
        for (request, directory) in scan.requests {
            do {
                try await importRequest(request, directory: directory, created: &report.imported)
                do { try inbox.remove(request.id) } catch { report.cleanupFailed += 1 }
            } catch StoreError.unavailable {
                report.failed += 1
                break
            } catch {
                report.failed += 1
            }
        }
        return report
    }

    private func importRequest(
        _ request: ShareRequest, directory: URL, created: inout [ItemID]
    ) async throws {
        var progress = loadProgress(directory)

        // A re-share only applies to a single entry.
        var reshareTarget: ItemID?
        if request.entries.count == 1, progress.done["0"] == nil, let existing = request.existingItem {
            do {
                _ = try await store.item(existing)
                reshareTarget = existing
            } catch StoreError.notFound {
                // The item was deleted meanwhile; import it as new.
            }
        }
        // A new share of a URL that is already in the library (the sheet's lookup can miss it).
        if reshareTarget == nil, request.entries.count == 1, progress.done["0"] == nil,
           request.existingItem == nil, let url = request.entries[0].url, request.entries[0].fileName == nil,
           let known = try await store.findItem(url: url) {
            let id = try await merge(request, entry: request.entries[0], into: known)
            progress.done["0"] = id.relativePath
            try saveProgress(progress, directory)
            created.append(id)
            return
        }
        if let existing = reshareTarget {
            let id = try await reshare(request, entry: request.entries[0], existing: existing)
            progress.done["0"] = id.relativePath
            try saveProgress(progress, directory)
            created.append(id)
            return
        }

        var target = request.collection
        if request.entries.count > 1 {
            if let saved = progress.collection {
                target = saved
            } else {
                target = try await store.createCollection(
                    named: request.newCollectionName ?? "Share", in: request.collection)
                progress.collection = target
                try saveProgress(progress, directory)
            }
        }
        for (index, entry) in request.entries.enumerated() where progress.done["\(index)"] == nil {
            let id = try await create(entry, request: request, directory: directory, in: target)
            progress.done["\(index)"] = id.relativePath
            try saveProgress(progress, directory)
            created.append(id)
        }
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

    /// Adds the share to `item`: highlight appended, tags unioned, note only if it had none,
    /// favorite if either is. Title, type and collection stay as they are.
    private func merge(_ request: ShareRequest, entry: ShareEntry, into item: Item) async throws -> ItemID {
        var merged = item
        if let highlight = entry.highlight, !merged.highlights.contains(highlight) { merged.highlights.append(highlight) }
        for tag in request.tags where !merged.tags.contains(tag) { merged.tags.append(tag) }
        if merged.note.isEmpty { merged.note = request.note }
        merged.favorite = item.favorite || request.favorite
        guard merged != item else { return item.id }
        return try await store.update(merged).id
    }

    private func create(
        _ entry: ShareEntry, request: ShareRequest, directory: URL, in collection: CollectionPath
    ) async throws -> ItemID {
        let isWebLink = entry.url != nil && entry.type != .text && entry.fileName == nil
        let draft = ItemDraft(
            type: entry.type, url: entry.url, title: entry.title, description: entry.description,
            tags: request.tags, favorite: request.favorite, note: request.note,
            content: entry.content, highlights: entry.highlight.map { [$0] } ?? [],
            created: request.created,
            fileSource: entry.fileName.map { directory.appending(path: $0) },
            previewImageSource: entry.previewImageName.map { directory.appending(path: $0) },
            capture: isWebLink ? .pending : nil)
        return try await store.create(draft, in: collection).id
    }

    private func loadProgress(_ directory: URL) -> Progress {
        let url = directory.appending(path: Self.progressFileName)
        guard let data = try? Data(contentsOf: url),
            let progress = try? JSONDecoder().decode(Progress.self, from: data)
        else { return Progress() }
        return progress
    }

    private func saveProgress(_ progress: Progress, _ directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(progress).write(
            to: directory.appending(path: Self.progressFileName), options: .atomic)
    }
}
