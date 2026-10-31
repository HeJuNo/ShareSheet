import Foundation
import Observation
import SharesheetCore

/// Ties the iCloud library, the index, the share inbox and the capture runner together for the UI.
@MainActor @Observable final class AppModel {
    private(set) var isICloudAvailable = true
    private(set) var counts = LibraryCounts()
    private(set) var collections: [CollectionPath] = []
    private(set) var tags: [String] = []
    private(set) var pendingCaptureCount = 0
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
            await Self.reindex(store: store, inbox: inbox, index: index)
            collections = (try? await store.collections()) ?? collections
        } else {
            collections = []
        }
        reloadFromIndex()
        startCaptures()
    }

    private func resolveStore() async -> (any ItemStore)? {
        if let store { return store }
        let resolved = await storeFactory()
        isICloudAvailable = resolved != nil
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

    nonisolated private static func reindex(store: any ItemStore, inbox: Inbox, index: LibraryIndex) async {
        _ = await InboxImporter(inbox: inbox, store: store).importAll()
        guard let items = try? await store.listItems() else { return }
        try? index.replaceAll(with: items)
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
        counts = (try? index.counts()) ?? LibraryCounts()
        tags = (try? index.allTags()) ?? []
        pendingCaptureCount = ((try? index.search(LibraryQuery(scope: .all))) ?? [])
            .filter { $0.capture == .pending }.count
        faviconCache = [:]
        revision += 1
    }

    // MARK: Captures

    /// Runs pending captures now; a request while a run is going makes it run once more.
    func capturePendingNow() {
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
        return (try? index.search(query)) ?? []
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

    func toggleFavorite(_ item: IndexedItem) async {
        guard let store, var full = try? await store.item(item.id) else { return }
        full.favorite.toggle()
        guard let saved = try? await store.update(full) else { return }
        try? index.upsert(saved)
        reloadFromIndex()
    }

    func delete(_ item: IndexedItem) async {
        guard let store, (try? await store.delete(item.id)) != nil else { return }
        try? index.remove(item.id)
        reloadFromIndex()
    }

    func createCollection(named name: String, in parent: CollectionPath) async -> CollectionPath? {
        guard let store, let path = try? await store.createCollection(named: name, in: parent) else { return nil }
        collections = (try? await store.collections()) ?? collections + [path]
        return path
    }

    /// Re-reads every file and re-extracts the archived page text, e.g. after a reinstall.
    func rebuildIndex() async {
        await refresh()
        guard let store else { return }
        await Self.reextractArchiveText(store: store, index: index)
        reloadFromIndex()
    }

    nonisolated private static func reextractArchiveText(store: any ItemStore, index: LibraryIndex) async {
        guard let items = try? await store.listItems() else { return }
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
        let runner = CaptureRunner(
            store: ResolvingItemStore(library: library), index: index, capturer: WebPageCapturer(),
            archiver: HTMLArchiver(fetcher: URLSessionFetcher()), favicons: FaviconFetcher())
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
            if let index = try? LibraryIndex(path: url) { return index }
        }
        fatalError("No writable location for the library index")
    }
}
