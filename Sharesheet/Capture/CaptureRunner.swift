import Foundation
import SharesheetCore

/// Captures screenshot and archive for saved web links, one item at a time.
actor CaptureRunner {
    private let store: any ItemStore
    private let index: LibraryIndex
    private let capturer: any PageCapturing
    private let archiver: HTMLArchiver
    private let favicons: FaviconFetcher
    private var tail: Task<Void, Never>?

    init(store: any ItemStore, index: LibraryIndex, capturer: any PageCapturing, archiver: HTMLArchiver, favicons: FaviconFetcher) {
        self.store = store
        self.index = index
        self.capturer = capturer
        self.archiver = archiver
        self.favicons = favicons
    }

    /// Captures items with `capture == .pending`, oldest first. Stops early when cancelled.
    func runPending(limit: Int? = nil) async -> (done: Int, failed: Int) {
        await serialized { await $0.capturePending(limit: limit) }
    }

    /// Captures one item with a url regardless of its current state (used for "Retry").
    func capture(_ id: ItemID) async {
        await serialized { await $0.captureOne(id) }
    }

    /// Runs operations one after another: actor methods interleave at every `await`, which would let a
    /// background run and a Retry capture the same item twice. Cancelling the caller cancels its operation.
    private func serialized<T: Sendable>(_ operation: @escaping @Sendable (CaptureRunner) async -> T) async -> T {
        let previous = tail
        let task = Task { [self] in
            await previous?.value
            return await operation(self)
        }
        tail = Task { _ = await task.value }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private enum Outcome { case done, failed, cancelled, gone }

    private func capturePending(limit: Int?) async -> (done: Int, failed: Int) {
        guard let all = try? await store.listItems() else { return (0, 0) }
        var pending = all.filter { $0.capture == .pending }.sorted { $0.created < $1.created }
        if let limit { pending = Array(pending.prefix(max(0, limit))) }
        var done = 0, failed = 0
        for item in pending {
            if Task.isCancelled { break }
            switch await process(item) {
            case .done: done += 1
            case .failed: failed += 1
            case .gone: continue
            case .cancelled: return (done, failed)
            }
        }
        return (done, failed)
    }

    private func captureOne(_ id: ItemID) async {
        guard let item = try? await store.item(id), item.url != nil else { return }
        _ = await process(item)
    }

    /// `.done` only when both screenshot and archive were saved. A cancelled capture leaves the item untouched;
    /// an item deleted or moved meanwhile (`.gone`) is neither written nor indexed.
    private func process(_ item: Item) async -> Outcome {
        var screenshot: String?, archive: String?, archiveText: String?, iconURL: URL?
        var succeeded = false

        if let url = item.url {
            do {
                let snapshot = try await capturer.capture(url)
                try Task.checkCancellation()
                screenshot = try await saveAttachment(snapshot.png, for: item, ext: "png")
                let html = try await archiver.archive(html: snapshot.domHTML, baseURL: snapshot.finalURL)
                try Task.checkCancellation()
                archive = try await saveAttachment(Data(html.utf8), for: item, ext: "html")
                archiveText = ArchiveText.extract(fromHTML: html)
                iconURL = snapshot.iconURL
                succeeded = true
            } catch {
                if error is CancellationError || Task.isCancelled { return .cancelled }
            }
        }

        // Re-read so edits made while capturing survive; only the capture fields are ours to change.
        guard var fresh = try? await store.item(item.id) else { return .gone }
        if let screenshot { fresh.screenshot = screenshot }
        if let archive { fresh.archive = archive }
        fresh.capture = succeeded ? .done : .failed
        guard let saved = try? await store.update(fresh) else { return .gone }
        try? index.upsert(saved)
        if let archive, let archiveText { try? index.setArchiveText(archiveText, forArchive: archive) }
        if succeeded { await storeFavicon(host: item.url?.host(), iconURL: iconURL) }
        return succeeded ? .done : .failed
    }

    private func saveAttachment(_ data: Data, for item: Item, ext: String) async throws -> String {
        let name = FileNamer.attachmentName(base: item.title, date: item.created, ext: ext, existing: [])
        let folder = FileManager.default.temporaryDirectory.appending(path: "capture-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: name)
        try data.write(to: file)
        return try await store.addAttachment(from: file, preferredName: name)
    }

    private func storeFavicon(host: String?, iconURL: URL?) async {
        guard let host, !host.isEmpty, (try? index.favicon(host: host)) == nil else { return }
        if let data = await favicons.fetch(host: host, iconURL: iconURL) {
            try? index.setFavicon(data, host: host)
        }
    }
}
