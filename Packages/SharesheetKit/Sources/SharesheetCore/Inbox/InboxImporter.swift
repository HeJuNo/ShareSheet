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
        /// The file an entry is being written to, saved before the write: after a crash between the write and
        /// `done`, a retry finds it instead of creating the item again.
        var writing: [String: String]?
    }

    private let inbox: Inbox
    private let store: any ItemStore
    private let now: @Sendable () -> Date
    private let remove: @Sendable (URL) throws -> Void

    public init(inbox: Inbox, store: any ItemStore) {
        self.init(inbox: inbox, store: store, now: { Date() })
    }

    /// Test seam: `now` dates claims, `remove` deletes a finished request's directory.
    init(
        inbox: Inbox, store: any ItemStore, now: @escaping @Sendable () -> Date,
        remove: (@Sendable (URL) throws -> Void)? = nil
    ) {
        self.inbox = inbox
        self.store = store
        self.now = now
        self.remove = remove ?? { try inbox.removeDirectory($0) }
    }

    /// Imports every pending request. Each one is claimed first, so the app and the share extension
    /// never import the same request at once.
    public func importAll() async -> ImportReport {
        await run(only: nil)
    }

    /// Imports only the request with this id (the share extension's own), if it is still pending.
    public func importRequest(_ id: UUID) async -> ImportReport {
        await run(only: id)
    }

    private func run(only id: UUID?) async -> ImportReport {
        var report = ImportReport()
        let scan: (requests: [(request: ShareRequest, directory: URL)], unreadable: Int)
        do {
            scan = try inbox.scan(now: now())
        } catch {
            report.failed = 1
            return report
        }
        if id == nil { report.unreadable = scan.unreadable }
        for (request, directory) in scan.requests where id == nil || request.id == id {
            // Another process claimed or finished it since the scan.
            guard let claimed = inbox.claim(directory, now: now()) else { continue }
            do {
                try await importRequest(request, directory: claimed, created: &report.imported)
                do {
                    try remove(claimed)
                } catch {
                    report.cleanupFailed += 1
                    inbox.release(claimed)
                }
            } catch StoreError.unavailable {
                report.failed += 1
                inbox.release(claimed)
                break
            } catch {
                report.failed += 1
                inbox.release(claimed)
            }
        }
        return report
    }

    private func importRequest(
        _ request: ShareRequest, directory: URL, created: inout [ItemID]
    ) async throws {
        var progress = loadProgress(directory)
        // Entries written before a crash that hit between the write and saving `done`.
        for (key, path) in progress.writing ?? [:] where progress.done[key] == nil {
            guard let index = Int(key), request.entries.indices.contains(index) else { continue }
            let entry = request.entries[index]
            let id = ItemID(relativePath: path)
            if let written = try? await store.item(id), written.url == entry.url, written.title == entry.title {
                progress.done[key] = path
                try saveProgress(progress, directory)
                created.append(id)
            }
        }

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
            let key = "\(index)"
            let reserved = progress
            let id = try await create(entry, request: request, directory: directory, in: target) { id in
                var writing = reserved
                writing.writing = (writing.writing ?? [:]).merging([key: id.relativePath]) { $1 }
                try saveProgress(writing, directory)
            }
            progress.done[key] = id.relativePath
            progress.writing?[key] = nil
            try saveProgress(progress, directory)
            created.append(id)
        }
    }

    /// Edits and highlight go onto the current file in one store step, so a capture written meanwhile survives.
    private func reshare(_ request: ShareRequest, entry: ShareEntry, existing: ItemID) async throws -> ItemID {
        let edits = request.edits ?? SheetEdits()
        let highlight = entry.highlight
        var item = try await store.modify(existing) { $0 = $0.applying(edits, highlight: highlight) }
        if let collection = edits.collection, collection != item.id.collection {
            item = try await store.move(item.id, to: collection)
        }
        return item.id
    }

    /// Adds the share to `item`: highlight appended, tags unioned, note only if it had none,
    /// favorite if either is. Title, type and collection stay as they are. One store step on the current file.
    private func merge(_ request: ShareRequest, entry: ShareEntry, into item: Item) async throws -> ItemID {
        let (highlight, tags, note, favorite) = (entry.highlight, request.tags, request.note, request.favorite)
        return try await store.modify(item.id) { merged in
            if let highlight, !merged.highlights.contains(highlight) { merged.highlights.append(highlight) }
            for tag in tags where !merged.tags.contains(tag) { merged.tags.append(tag) }
            if merged.note.isEmpty { merged.note = note }
            merged.favorite = merged.favorite || favorite
        }.id
    }

    private func create(
        _ entry: ShareEntry, request: ShareRequest, directory: URL, in collection: CollectionPath,
        willWrite: @Sendable (ItemID) throws -> Void
    ) async throws -> ItemID {
        let isWebLink = entry.url?.isWebPage == true && entry.type != .text && entry.fileName == nil
        let draft = ItemDraft(
            type: entry.type, url: entry.url, title: entry.title, description: entry.description,
            tags: request.tags, favorite: request.favorite, note: request.note,
            content: entry.content, highlights: entry.highlight.map { [$0] } ?? [],
            created: request.created,
            fileSource: entry.fileName.map { directory.appending(path: $0) },
            previewImageSource: entry.previewImageName.map { directory.appending(path: $0) },
            capture: isWebLink ? .pending : nil)
        return try await store.create(draft, in: collection, willWrite: willWrite).id
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
