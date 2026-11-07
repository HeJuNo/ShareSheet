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

/// The user's choices for document analysis, read from `UserDefaults` whenever they are needed.
enum AnalysisSettings {
    static let enabledKey = "analyzeDocuments"
    static let tagModeKey = "tagMode"

    /// On unless switched off.
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    /// `suggest` when unset or not a known mode.
    static func tagMode(_ defaults: UserDefaults = .standard) -> TagMode {
        defaults.string(forKey: tagModeKey).flatMap(TagMode.init(rawValue:)) ?? .suggest
    }
}

/// The user's choices for the Trash, read from `UserDefaults` whenever they are needed.
enum TrashSettings {
    static let autoEmptyKey = "trashAutoEmpty"
    static let daysKey = "trashRetentionDays"
    static let dayChoices = [7, 14, 30, 60, 90]

    /// On unless switched off.
    static func autoEmpties(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: autoEmptyKey) as? Bool ?? true
    }

    /// 30 when unset or not one of the choices.
    static func retentionDays(_ defaults: UserDefaults = .standard) -> Int {
        let days = defaults.integer(forKey: daysKey)
        return dayChoices.contains(days) ? days : 30
    }
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
    /// Deleted items, newest first.
    private(set) var trashed: [TrashedItem] = []
    /// The item the last delete moved to the Trash; the "Undo" banner offers to take it back.
    var lastDeleted: TrashedItem?
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
    @ObservationIgnored private let analyzer: DocumentAnalyzer?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let isForeground: @Sendable () async -> Bool
    /// Which aggregate the list footer shows per field name, by the rules; see `fieldStats`.
    private(set) var fieldAggregates: [String: FieldAggregate] = [:]
    /// Where rules moved items to; the detail screen still holds the id from before.
    @ObservationIgnored private let redirects: MoveRedirects
    let rulesStatus: RulesStatus
    @ObservationIgnored private let ruleApplier: RuleApplier?
    @ObservationIgnored private let rulesRoot: () async -> URL?
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var analysisRequested = false
    @ObservationIgnored private var faviconCache: [String: Data?] = [:]

    /// `extensionTemporaryRoot` is the share extension's `Tmp` folder; its leftovers older than an hour are swept.
    init(
        storeFactory: @escaping () async -> (any ItemStore)?, index: LibraryIndex, inbox: Inbox,
        runner: CaptureRunner?, extensionTemporaryRoot: URL? = nil,
        analyzer: DocumentAnalyzer? = nil, defaults: UserDefaults = .standard,
        isForeground: @escaping @Sendable () async -> Bool = { true },
        redirects: MoveRedirects = MoveRedirects(), rulesStatus: RulesStatus = RulesStatus(),
        ruleApplier: RuleApplier? = nil, rulesRoot: @escaping () async -> URL? = { await ICloudLocator.libraryRoot() }
    ) {
        self.ruleApplier = ruleApplier
        self.rulesRoot = rulesRoot
        self.redirects = redirects
        self.rulesStatus = rulesStatus
        self.isForeground = isForeground
        self.analyzer = analyzer
        self.defaults = defaults
        self.storeFactory = storeFactory
        self.index = index
        self.inbox = inbox
        self.runner = runner
        self.extensionTemporaryRoot = extensionTemporaryRoot
    }

    /// The rules editor's model on this library.
    func makeRulesModel() -> RulesModel {
        RulesModel(
            root: rulesRoot, applier: ruleApplier, onSaved: { [weak self] in await self?.reloadFieldAggregates() },
            itemIDs: { [index] in ((try? index.search(LibraryQuery(scope: .all))) ?? []).map(\.id) })
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
    /// Analysis is not awaited (and does not start in the background, see `startAnalysis`).
    func refreshAndCapture() async {
        await refresh()
        if let task = captureTask {
            await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        }
    }

    /// Returns when the analysis run that is going (if any) has ended.
    func analysisFinished() async {
        await analysisTask?.value
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
        await reloadFieldAggregates()
        await purgeExpired()
        startCaptures()
        startAnalysis()
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

    /// Cancels running captures and waits until they stopped; interrupted items stay pending for the background
    /// task. Called when the app leaves the foreground: a capture frozen at suspension would keep its attempt
    /// marker, and if the system then evicted the app the next launch would mark that item failed.
    func stopCaptures() async {
        analysisRequested = false
        captureRequested = false
        analysisTask?.cancel()
        captureTask?.cancel()
        // Waits for the runs to notice the cancellation. The app does not wait for this before it suspends the
        // index (`SharesheetApp` starts this in a task and calls `LibraryIndex.suspend()` right away): GRDB then
        // refuses further access and the analyzer's index writes are `try?`, so an item in flight is simply
        // analyzed again later.
        await captureTask?.value
        analysisRequested = false
        analysisTask?.cancel()
        await analysisTask?.value
    }

    /// True while an analysis run is going.
    var isAnalyzing: Bool { analysisTask != nil }

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

    /// Runs pending captures now; a request while a run is going makes it run once more.
    func startCaptures() {
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
            // The pages captured now have their text in the index; not when stopping.
            if !Task.isCancelled { self?.startAnalysis() }
        }
    }

    // MARK: Analysis

    /// Analyzes new documents and pages once running captures have ended (a page is read from its archive text,
    /// which the capture writes); a request while a run is going makes it run once more.
    private func startAnalysis() {
        guard analyzer != nil, isICloudAvailable else { return }
        if analysisTask != nil {
            analysisRequested = true
            return
        }
        analysisTask = Task { [weak self] in
            repeat {
                self?.analysisRequested = false
                if let capturing = self?.captureTask { await capturing.value }
                guard let self, !Task.isCancelled else { break }
                // Only in the foreground: the background task must not wait for (or start) a long analysis.
                if AnalysisSettings.isEnabled(self.defaults), let analyzer = self.analyzer,
                    await self.isForeground(), !Task.isCancelled
                {
                    _ = await analyzer.runPending()
                }
            } while !Task.isCancelled && self?.analysisRequested == true
            self?.analysisTask = nil
            self?.reloadFromIndex()
        }
    }

    /// Forgets all keywords and suggestions and analyzes every document again.
    func analyzeAgain() {
        do {
            try index.clearAnalysis()
        } catch {
            Self.log.error("Clearing the analysis failed: \(error)")
        }
        reloadFromIndex()
        startAnalysis()
    }

    func analysis(for id: ItemID) -> ItemAnalysis? {
        _ = revision
        return try? index.analysis(forItem: id)
    }

    /// The suggested tag to show, none when the item carries it already (e.g. added by hand since).
    nonisolated static func visibleSuggestion(_ suggestion: String?, itemTags: [String]) -> String? {
        guard let tag = suggestion,
            !itemTags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame })
        else { return nil }
        return tag
    }

    /// Adds `tag`, spelled like an existing tag when one matches, to the item's file in one store step, then
    /// drops the suggestion (also when the item is gone or the tag is unusable).
    func acceptSuggestedTag(_ tag: String, for id: ItemID) async throws {
        let store = try requireStore()
        guard let resolved = TagCatalog.resolve(tag, among: (try? index.allTags()) ?? []) else {
            dismissSuggestedTag(for: id)
            return
        }
        do {
            let saved = try await store.modify(id) { item in
                if !DocumentAnalyzer.carries(item.tags, resolved) { item.tags.append(resolved) }
            }
            try? index.upsert(saved)
        } catch {
            if case StoreError.notFound = error { dismissSuggestedTag(for: id) }
            Self.log.error("Accepting a suggested tag failed: \(error)")
            throw error
        }
        try? index.setSuggestedTag(nil, forItem: id)
        reloadFromIndex()
    }

    func dismissSuggestedTag(for id: ItemID) {
        try? index.setSuggestedTag(nil, forItem: id)
        reloadFromIndex()
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

    /// One line per number field over the items of `query`, for the footer of a list: the aggregate the rules choose
    /// for that field (the sum when none does), and how many items have it. `value` is nil when it has no result.
    func fieldStats(_ query: LibraryQuery) -> [FieldStat] {
        _ = revision
        guard let values = try? index.fieldValues(query) else { return [] }
        return values.keys.sorted().map { name in
            let aggregate = fieldAggregates[name] ?? .sum
            return FieldStat(name: name, aggregate: aggregate, value: aggregate.value(of: values[name] ?? []), count: values[name]?.count ?? 0)
        }
    }

    /// Reads which aggregate each field uses from `rules.json`; the list footers follow it.
    func reloadFieldAggregates() async {
        guard let root = await rulesRoot(), case .rules(let set) = RuleFile.load(from: root) else {
            fieldAggregates = [:]
            return
        }
        fieldAggregates = set.aggregates
    }

    /// Sets a field by hand: rules leave it alone from now on. Returns the saved item.
    @discardableResult
    func setField(_ id: ItemID, name: String, value: FieldValue) async throws -> Item {
        try await changeFields(id) { item in
            item.fields[name] = value
            item.fieldsManual.insert(name)
            item.fieldsDeleted.remove(name)
        }
    }

    /// Deletes a field by hand: rules do not set it again. Returns the saved item.
    @discardableResult
    func deleteField(_ id: ItemID, name: String) async throws -> Item {
        try await changeFields(id) { item in
            item.fields[name] = nil
            item.fieldsManual.remove(name)
            item.fieldsDeleted.insert(name)
        }
    }

    private func changeFields(_ id: ItemID, _ change: @escaping @Sendable (inout Item) -> Void) async throws -> Item {
        let store = try requireStore()
        let saved: Item
        do {
            saved = try await store.modify(redirects.current(id), change)
        } catch {
            Self.log.error("Changing a field failed: \(error)")
            throw error
        }
        try? index.upsert(saved)
        reloadFromIndex()
        return saved
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
        try await requireStore().item(redirects.current(id))
    }

    /// Writes the user-editable fields (title, note, tags, favorite) of `item` onto its file in one store
    /// step, so capture results written meanwhile survive. Throws `StoreError.notFound` when it is gone.
    func save(_ item: Item) async throws -> Item {
        let store = try requireStore()
        let saved: Item
        do {
            let (title, note, tags, favorite) = (item.title, item.note, item.tags, item.favorite)
            // The date is written only when it was set by hand, so a screen holding an old date cannot undo a
            // date a rule set meanwhile.
            let (created, byHand, titleByHand) = (item.created, item.createdManual, item.titleManual)
            saved = try await store.modify(redirects.current(item.id)) {
                $0.title = title
                if titleByHand { $0.titleManual = true }
                $0.note = note
                $0.tags = tags
                $0.favorite = favorite
                if byHand {
                    $0.created = created
                    $0.createdManual = true
                }
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
        let id = redirects.current(id)
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
        let id = redirects.current(id)
        let store = try requireStore()
        // A new file may take over the freed name, so the analysis of the old one must not outlive it.
        let gone = try? await store.item(id)
        do {
            try await store.delete(id)
        } catch {
            Self.log.error("Deleting an item failed: \(error)")
            throw error
        }
        try? index.remove(id)
        if let source = gone?.file ?? gone?.archive { try? index.removeAnalysis(forSource: source) }
        reloadFromIndex()
        await reloadTrash()
        // The entry this delete just made is the newest one; the user may take it back for a few seconds.
        lastDeleted = trashed.first
    }

    // MARK: Trash

    private var trashStore: (any TrashStore)? { store as? any TrashStore }

    func reloadTrash() async {
        trashed = (try? await trashStore?.trashedItems()) ?? []
    }

    /// Puts an item back where it was and into the index. Returns the restored item.
    @discardableResult
    func restore(_ entry: TrashedItem) async throws -> Item {
        guard let trashStore else { throw StoreError.unavailable }
        let item = try await trashStore.restore(entry.id)
        try? index.upsert(item)
        if lastDeleted == entry { lastDeleted = nil }
        reloadFromIndex()
        await reloadTrash()
        startAnalysis()
        return item
    }

    func purge(_ entry: TrashedItem) async throws {
        guard let trashStore else { throw StoreError.unavailable }
        try await trashStore.purge(entry.id)
        if lastDeleted == entry { lastDeleted = nil }
        await reloadTrash()
    }

    func emptyTrash() async throws {
        guard let trashStore else { throw StoreError.unavailable }
        try await trashStore.emptyTrash()
        lastDeleted = nil
        await reloadTrash()
    }

    /// Deletes items that have been in the Trash longer than the chosen time, unless that is switched off.
    /// This is the only place that deletes for good by itself. Returns how many items it removed.
    @discardableResult
    func purgeExpired(now: Date = Date(), defaults: UserDefaults = .standard) async -> Int {
        guard TrashSettings.autoEmpties(defaults), let trashStore else {
            await reloadTrash()
            return 0
        }
        let cutoff = now.addingTimeInterval(-Double(TrashSettings.retentionDays(defaults)) * 86_400)
        let removed = (try? await trashStore.purgeTrash(olderThan: cutoff)) ?? 0
        await reloadTrash()
        return removed
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
        await runner?.capture(redirects.current(id))
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

    /// The rules from `rules.json` in the library, read fresh for every item; nil when the ZEN engine cannot start.
    /// A missing or broken file means no rules.
    private static func liveRules(
        library: ICloudLibrary, index: LibraryIndex, redirects: MoveRedirects, status: RulesStatus
    ) -> RuleApplier? {
        guard let engine = try? RuleEngine() else { return nil }
        return RuleApplier(
            store: ResolvingItemStore(library: library), index: index, redirects: redirects,
            rules: { await RulesLoading.load(root: await ICloudLocator.libraryRoot(), status: status) },
            evaluate: { set, item, text in try await engine.outcome(for: set, item: item, text: text) })
    }

    private static func live() -> AppModel {
        let library = ICloudLibrary()
        let index = openIndex()
        let fm = FileManager.default
        let inbox = Inbox(root: AppGroup.inboxURL() ?? fm.temporaryDirectory.appending(path: "Inbox"))
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let redirects = MoveRedirects()
        let rulesStatus = RulesStatus()
        let rules = liveRules(library: library, index: index, redirects: redirects, status: rulesStatus)
        let runner = CaptureRunner(
            store: ResolvingItemStore(library: library), index: index, capturer: WebPageCapturer(),
            archiver: HTMLArchiver(fetcher: URLSessionFetcher()), favicons: FaviconFetcher(),
            embeds: URLSessionFetcher(), attemptMarker: caches.appending(path: "capture-attempt"),
            isForeground: { await UIApplication.shared.applicationState == .active }, rules: rules)
        let analyzer = DocumentAnalyzer(
            store: ResolvingItemStore(library: library), index: index, tagger: FallbackTagger(
                primary: FoundationModelsTagger(),
                fallback: LocalTagger(examples: { (try? index.taggedExamples(limit: LocalTagger.maxExamples)) ?? [] })),
            tagMode: { AnalysisSettings.tagMode() }, rules: rules)
        return AppModel(
            storeFactory: { await library.resolve() }, index: index, inbox: inbox, runner: runner,
            extensionTemporaryRoot: AppGroup.containerURL()?.appending(path: "Tmp", directoryHint: .isDirectory),
            analyzer: analyzer, isForeground: { await UIApplication.shared.applicationState == .active },
            redirects: redirects, rulesStatus: rulesStatus, ruleApplier: rules)
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

/// A number field over a list: its aggregate, the result (nil when the values do not allow one) and the item count.
struct FieldStat: Equatable, Identifiable, Sendable {
    var name: String
    var aggregate: FieldAggregate
    var value: Double?
    var count: Int
    var id: String { name }
}
