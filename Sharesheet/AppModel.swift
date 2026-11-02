import Foundation
import Observation
import OSLog
import SharesheetCore
import UIKit

enum ICloudState: Equatable {
    /// The store factory has not answered yet.
    case unknown
    case available
    case unavailable
}

enum AppModelError: Error, Equatable {
    /// Empty, or reserved (`_attachments`, names starting with `.`).
    case invalidCollectionName
}

/// Ties the iCloud library, the index, the share inbox and the capture runner together for the UI.
@MainActor @Observable final class AppModel {
    nonisolated private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Sharesheet", category: "Library")

    private(set) var iCloudState = ICloudState.unknown
    var isICloudAvailable: Bool { iCloudState == .available }
    private(set) var counts = LibraryCounts()
    private(set) var collections: [CollectionPath] = []
    private(set) var tags: [String] = []
    private(set) var pendingCaptureCount = 0
    private(set) var failedCaptureCount = 0
    /// Inbox requests the last import could not take in (failed or unreadable); they stay in the inbox.
    private(set) var lastImportProblemCount = 0
    /// Bumped whenever the index changed, so views reading `items(_:)` re-render.
    private(set) var revision = 0

    @ObservationIgnored private let storeFactory: () async -> (any ItemStore)?
    @ObservationIgnored private let index: LibraryIndex
    @ObservationIgnored private let inbox: Inbox
    @ObservationIgnored let runner: CaptureRunner?
    @ObservationIgnored private let extensionTemporaryRoot: URL?

    @ObservationIgnored private var store: (any ItemStore)?
    @ObservationIgnored private var changesTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var refreshRequested = false
    @ObservationIgnored private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var captureTask: Task<Void, Never>?
    @ObservationIgnored private var captureRequested = false
    @ObservationIgnored private var faviconCache: [String: Data?] = [:]

    /// `extensionTemporaryRoot` is the share extension's `Tmp` folder; its leftovers older than an hour are swept.
    init(
        storeFactory: @escaping () async -> (any ItemStore)?, index: LibraryIndex, inbox: Inbox,
        runner: CaptureRunner?, extensionTemporaryRoot: URL? = nil
    ) {
        self.storeFactory = storeFactory
        self.index = index
        self.inbox = inbox
        self.runner = runner
        self.extensionTemporaryRoot = extensionTemporaryRoot
    }

    // MARK: Refresh

    /// Imports the inbox, re-indexes the library and starts pending captures (without waiting for them).
    /// A call while a refresh runs makes that refresh run once more and returns when it has.
    func refresh() async {
        if isRefreshing {
            refreshRequested = true
            await withCheckedContinuation { refreshWaiters.append($0) }
            return
        }
        isRefreshing = true
        repeat {
            refreshRequested = false
            await performRefresh()
        } while refreshRequested
        isRefreshing = false
        let waiters = refreshWaiters
        refreshWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// For the background task: refreshes, then waits for the captures it started. Cancelling stops them.
    func refreshAndCapture() async {
        await refresh()
        guard let task = captureTask else { return }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func performRefresh() async {
        if let extensionTemporaryRoot { await Self.sweep(extensionTemporaryRoot) }
        let store = await resolveStore()
        if let store {
            let report = await Self.reindex(store: store, inbox: inbox, index: index)
            lastImportProblemCount = report.failed + report.unreadable
            do {
                collections = try await store.collections()
            } catch {
                Self.log.error("Listing collections failed: \(error)")
            }
        } else {
            collections = []
        }
        reloadFromIndex()
        startCaptures()
    }

    private func resolveStore() async -> (any ItemStore)? {
        if let store { return store }
        let resolved = await storeFactory()
        iCloudState = resolved == nil ? .unavailable : .available
        guard let resolved else { return nil }
        store = resolved
        listen(to: resolved)
        return resolved
    }

    private func listen(to store: any ItemStore) {
        guard changesTask == nil else { return }
        let changes = store.changes()
        changesTask = Task { [weak self] in
            for await _ in changes { self?.storeDidChange() }
        }
    }

    private func storeDidChange() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    nonisolated private static func reindex(store: any ItemStore, inbox: Inbox, index: LibraryIndex) async -> ImportReport {
        let report = await InboxImporter(inbox: inbox, store: store).importAll()
        if report.failed + report.unreadable + report.cleanupFailed > 0 {
            log.error(
                "Inbox import: \(report.imported.count) imported, \(report.failed) failed, \(report.unreadable) unreadable, \(report.cleanupFailed) not cleaned up")
        }
        do {
            try index.replaceAll(with: try await store.listItems())
        } catch {
            log.error("Re-indexing the library failed: \(error)")
        }
        return report
    }

    /// Removes the share extension's per-share folders left behind for more than an hour.
    nonisolated private static func sweep(_ root: URL) async {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-3600)
        guard let folders = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        else { return }
        for folder in folders {
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? fm.removeItem(at: folder) }
        }
    }

    private func reloadFromIndex() {
        do {
            counts = try index.counts()
            tags = try index.allTags()
            let all = try index.search(LibraryQuery(scope: .all))
            pendingCaptureCount = all.filter { $0.capture == .pending }.count
            failedCaptureCount = all.filter { $0.capture == .failed }.count
        } catch {
            Self.log.error("Reading the index failed: \(error)")
        }
        faviconCache = [:]
        revision += 1
    }

    // MARK: Captures

    /// Runs pending captures now; a request while a run is going makes it run once more.
    func capturePendingNow() {
        startCaptures()
    }

    /// Cancels running captures and waits until they stopped; interrupted items stay pending for the background
    /// task. Called when the app leaves the foreground: a capture frozen at suspension would keep its attempt
    /// marker, and if the system then evicted the app the next launch would mark that item failed.
    func stopCaptures() async {
        guard let task = captureTask else { return }
        captureRequested = false
        task.cancel()
        await task.value
    }

    /// Makes every failed capture pending again, then runs the pending captures.
    func retryFailedCaptures() async {
        guard let store else { return }
        do {
            for item in try await store.listItems() where item.capture == .failed {
                do {
                    let saved = try await store.modify(item.id) { if $0.capture == .failed { $0.capture = .pending } }
                    try? index.upsert(saved)
                } catch StoreError.notFound {
                    continue
                }
            }
        } catch {
            Self.log.error("Retrying failed captures failed: \(error)")
        }
        reloadFromIndex()
        startCaptures()
    }

    private func startCaptures() {
        guard let runner, isICloudAvailable else { return }
        if captureTask != nil {
            captureRequested = true
            return
        }
        captureTask = Task { [weak self] in
            repeat {
                self?.captureRequested = false
                _ = await runner.runPending()
            } while !Task.isCancelled && self?.captureRequested == true
            self?.captureTask = nil
            self?.reloadFromIndex()
        }
    }

    // MARK: Reading

    func items(_ query: LibraryQuery) -> [IndexedItem] {
        _ = revision
        do {
            return try index.search(query)
        } catch {
            Self.log.error("Searching the index failed: \(error)")
            return []
        }
    }

    /// Favicons are stored by full host (`www.` included), as the capture runner saves them.
    func favicon(for item: IndexedItem) -> Data? {
        guard let host = item.url?.host(), !host.isEmpty else { return nil }
        if let cached = faviconCache[host] { return cached }
        let data = try? index.favicon(host: host)
        faviconCache[host] = data
        return data
    }

    // MARK: Editing

    func toggleFavorite(_ item: IndexedItem) async throws {
        let store = try requireStore()
        do {
            let saved = try await store.modify(item.id) { $0.favorite.toggle() }
            try? index.upsert(saved)
        } catch {
            Self.log.error("Toggling favorite failed: \(error)")
            throw error
        }
        reloadFromIndex()
    }

    func delete(_ item: IndexedItem) async throws {
        try await delete(item.id)
    }

    func loadItem(_ id: ItemID) async throws -> Item {
        try await requireStore().item(id)
    }

    /// Writes the user-editable fields (title, note, tags, favorite) of `item` onto its file in one store
    /// step, so capture results written meanwhile survive. Throws `StoreError.notFound` when it is gone.
    func save(_ item: Item) async throws -> Item {
        let store = try requireStore()
        let saved: Item
        do {
            let (title, note, tags, favorite) = (item.title, item.note, item.tags, item.favorite)
            saved = try await store.modify(item.id) {
                $0.title = title
                $0.note = note
                $0.tags = tags
                $0.favorite = favorite
            }
        } catch {
            Self.log.error("Saving an item failed: \(error)")
            throw error
        }
        try? index.upsert(saved)
        reloadFromIndex()
        return saved
    }

    /// Returns the item's new id.
    func move(_ id: ItemID, to collection: CollectionPath) async throws -> ItemID {
        let store = try requireStore()
        let moved: Item
        do {
            moved = try await store.move(id, to: collection)
        } catch {
            Self.log.error("Moving an item failed: \(error)")
            throw error
        }
        try? index.remove(id)
        try? index.upsert(moved)
        reloadFromIndex()
        return moved.id
    }

    func delete(_ id: ItemID) async throws {
        let store = try requireStore()
        do {
            try await store.delete(id)
        } catch {
            Self.log.error("Deleting an item failed: \(error)")
            throw error
        }
        try? index.remove(id)
        reloadFromIndex()
    }

    func createCollection(named name: String, in parent: CollectionPath) async throws -> CollectionPath {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "_attachments", !trimmed.hasPrefix(".") else {
            throw AppModelError.invalidCollectionName
        }
        let store = try requireStore()
        do {
            let path = try await store.createCollection(named: trimmed, in: parent)
            collections = (try? await store.collections()) ?? collections + [path]
            return path
        } catch {
            Self.log.error("Creating a collection failed: \(error)")
            throw error
        }
    }

    /// Without moving, a collection holding anything throws `StoreError.collectionNotEmpty`.
    /// Items of nested collections are moved too. `Unsorted` cannot be deleted.
    func deleteCollection(_ path: CollectionPath, moveItemsToUnsorted: Bool) async throws {
        let store = try requireStore()
        var failure: (any Error)?
        do {
            try await store.deleteCollection(path, moveItemsTo: moveItemsToUnsorted ? .unsorted : nil)
        } catch {
            Self.log.error("Deleting a collection failed: \(error)")
            failure = error
        }
        // Items may have moved even when the delete failed part way: their ids changed.
        if moveItemsToUnsorted {
            do {
                try index.replaceAll(with: try await store.listItems())
            } catch {
                Self.log.error("Re-indexing after a collection delete failed: \(error)")
            }
        }
        collections = (try? await store.collections()) ?? collections
        reloadFromIndex()
        if let failure { throw failure }
    }

    /// Captures the item now (Retry or Capture now), whatever its capture state.
    func retryCapture(_ id: ItemID) async {
        await runner?.capture(id)
        reloadFromIndex()
    }

    /// nil when the store is unavailable or the file is missing.
    /// How long `attachmentURL` waits for a file iCloud is still downloading.
    var downloadTimeout: Duration = .seconds(60)

    /// The attachment's file, waiting while iCloud downloads it; nil when it is gone or never arrives.
    func attachmentURL(_ relativePath: String) async -> URL? {
        let clock = ContinuousClock()
        let deadline = clock.now + downloadTimeout
        while true {
            do {
                let url = try await requireStore().attachmentURL(relativePath)
                if Self.isDownloaded(url) { return url }
            } catch StoreError.downloading {
                // Requested by the store; wait for it below.
            } catch {
                return nil
            }
            guard clock.now < deadline, !Task.isCancelled else { return nil }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// False for an iCloud file whose content is not on the device yet, whose download this then requests.
    nonisolated private static func isDownloaded(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard values?.isUbiquitousItem == true, let status = values?.ubiquitousItemDownloadingStatus,
            status != .current
        else { return true }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        return false
    }

    private func requireStore() throws -> any ItemStore {
        guard let store else { throw StoreError.unavailable }
        return store
    }

    /// Re-reads every file and re-extracts the archived page text, e.g. after a reinstall.
    func rebuildIndex() async {
        await refresh()
        guard let store else { return }
        await Self.reextractArchiveText(store: store, index: index)
        reloadFromIndex()
    }

    nonisolated private static func reextractArchiveText(store: any ItemStore, index: LibraryIndex) async {
        let items: [Item]
        do {
            items = try await store.listItems()
        } catch {
            log.error("Listing items for the archive text failed: \(error)")
            return
        }
        for archive in Set(items.compactMap(\.archive)) {
            guard let url = try? await store.attachmentURL(archive),
                let html = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            try? index.setArchiveText(ArchiveText.extract(fromHTML: html), forArchive: archive)
        }
    }
}

extension AppModel {
    /// The app's model on the iCloud library, the App Group index and inbox, with a live capture runner.
    static let shared = live()

    private static func live() -> AppModel {
        let library = ICloudLibrary()
        let index = openIndex()
        let fm = FileManager.default
        let inbox = Inbox(root: AppGroup.inboxURL() ?? fm.temporaryDirectory.appending(path: "Inbox"))
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let runner = CaptureRunner(
            store: ResolvingItemStore(library: library), index: index, capturer: WebPageCapturer(),
            archiver: HTMLArchiver(fetcher: URLSessionFetcher()), favicons: FaviconFetcher(),
            embeds: URLSessionFetcher(), attemptMarker: caches.appending(path: "capture-attempt"),
            isForeground: { await UIApplication.shared.applicationState == .active })
        return AppModel(
            storeFactory: { await library.resolve() }, index: index, inbox: inbox, runner: runner,
            extensionTemporaryRoot: AppGroup.containerURL()?.appending(path: "Tmp", directoryHint: .isDirectory))
    }

    /// The App Group index the share extension reads; a private fallback when the group is missing.
    private static func openIndex() -> LibraryIndex {
        let fm = FileManager.default
        let fallbacks = [fm.urls(for: .cachesDirectory, in: .userDomainMask).first, fm.temporaryDirectory]
            .compactMap { $0?.appending(path: "index.sqlite") }
        for url in [AppGroup.indexURL()].compactMap({ $0 }) + fallbacks {
            if let index = try? LibraryIndex(path: url, observesSuspension: true) { return index }
        }
        fatalError("No writable location for the library index")
    }
}
