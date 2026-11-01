import Foundation
import SharesheetCore

/// Captures screenshot and archive for saved web links, one item at a time.
actor CaptureRunner {
    private let store: any ItemStore
    private let index: LibraryIndex
    private let capturer: any PageCapturing
    private let archiver: HTMLArchiver
    private let favicons: FaviconFetcher
    /// Fetches oEmbed responses for social posts; nil captures every link as a page.
    private let embeds: (any ResourceFetching)?
    /// Where a short link redirects to; nil when it cannot be followed.
    private let resolveRedirects: @Sendable (URL) async -> URL?
    private let attemptMarker: URL?
    private let isForeground: @Sendable () async -> Bool
    private var tail: Task<Void, Never>?
    private var checkedAttemptMarker = false

    /// `attemptMarker` is a file naming the item being captured while a capture runs: one left behind means the
    /// process died capturing it, and that item is marked failed instead of being tried again forever.
    /// `isForeground` decides whether a capture timeout is final (foreground) or retried later (background).
    init(
        store: any ItemStore, index: LibraryIndex, capturer: any PageCapturing, archiver: HTMLArchiver,
        favicons: FaviconFetcher, embeds: (any ResourceFetching)? = nil,
        resolveRedirects: @escaping @Sendable (URL) async -> URL? = CaptureRunner.followRedirects,
        attemptMarker: URL? = nil, isForeground: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.embeds = embeds
        self.resolveRedirects = resolveRedirects
        self.store = store
        self.index = index
        self.capturer = capturer
        self.archiver = archiver
        self.favicons = favicons
        self.attemptMarker = attemptMarker
        self.isForeground = isForeground
    }

    /// Captures items with `capture == .pending`, oldest first. Stops early when cancelled.
    func runPending(limit: Int? = nil) async -> (done: Int, failed: Int) {
        await serialized {
            await $0.failItemOfAnInterruptedAttempt()
            return await $0.capturePending(limit: limit)
        }
    }

    /// Captures one item with a url regardless of its current state (used for "Retry").
    func capture(_ id: ItemID) async {
        await serialized {
            await $0.failItemOfAnInterruptedAttempt()
            await $0.captureOne(id)
        }
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

    /// `deferred`: a transient failure; the item stays pending for a later run. `skipped`: not a web page.
    private enum Outcome { case done, failed, deferred, skipped, cancelled, gone }

    /// Once per runner (i.e. per launch): an attempt marker left behind means the process died capturing that
    /// item; if it is still pending it is marked failed, so a page that crashes the app is not retried forever.
    private func failItemOfAnInterruptedAttempt() async {
        guard !checkedAttemptMarker, let attemptMarker else { return }
        guard let data = try? Data(contentsOf: attemptMarker) else {
            checkedAttemptMarker = true
            return
        }
        let id = ItemID(relativePath: String(decoding: data, as: UTF8.self))
        do {
            let saved = try await store.modify(id) { if $0.capture == .pending { $0.capture = .failed } }
            try? index.upsert(saved)
        } catch StoreError.notFound {
            // Deleted or moved meanwhile.
        } catch {
            return  // The library is unavailable: look again on the next run.
        }
        try? FileManager.default.removeItem(at: attemptMarker)
        checkedAttemptMarker = true
    }

    private func recordAttempt(_ id: ItemID) {
        guard let attemptMarker else { return }
        try? FileManager.default.createDirectory(
            at: attemptMarker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(id.relativePath.utf8).write(to: attemptMarker, options: .atomic)
    }

    private func clearAttempt() {
        guard let attemptMarker else { return }
        try? FileManager.default.removeItem(at: attemptMarker)
    }

    /// Network conditions that pass: the capture is tried again later rather than marked failed.
    private static let transientNetworkCodes: Set<Int> = [
        NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
        NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff, NSURLErrorCannotFindHost,
        NSURLErrorCannotConnectToHost,
    ]

    private func isTransient(_ error: any Error) async -> Bool {
        switch error {
        case CaptureError.network(let code): return Self.transientNetworkCodes.contains(code)
        case let error as URLError: return Self.transientNetworkCodes.contains(error.errorCode)
        // A timeout in the background may only mean the system starved the web view.
        case CaptureError.timeout: return !(await isForeground())
        default: return false
        }
    }

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
            case .deferred, .skipped, .gone: continue
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
    /// an item deleted or moved meanwhile (`.gone`) is neither written nor indexed. An item without an http(s)
    /// url gets no capture state at all, so it is not picked up again.
    private func process(_ item: Item) async -> Outcome {
        guard let url = item.url, url.isWebPage else {
            guard let saved = try? await store.modify(item.id, { $0.capture = nil }) else { return .gone }
            try? index.upsert(saved)
            return .skipped
        }
        var screenshot: String?, archive: String?, archiveText: String?, iconURL: URL?, postText: String?
        var succeeded = false
        var transient = false

        recordAttempt(item.id)
        defer { clearAttempt() }
        do {
            let embed = await socialEmbed(for: url)
            let snapshot: PageSnapshot
            if let embed {
                snapshot = try await capturer.capture(html: embed.page, baseURL: url)
                postText = embed.text
            } else {
                snapshot = try await capturer.capture(url)
            }
            try Task.checkCancellation()
            screenshot = try await saveAttachment(snapshot.png, for: item, ext: "png")
            // An embedded post's rendered DOM is only iframes; its markup still carries the post text.
            let html = try await archiver.archive(html: embed?.page ?? snapshot.domHTML, baseURL: snapshot.finalURL)
            try Task.checkCancellation()
            archive = try await saveAttachment(Data(html.utf8), for: item, ext: "html")
            archiveText = ArchiveText.extract(fromHTML: html)
            iconURL = snapshot.iconURL
            succeeded = true
        } catch {
            if error is CancellationError || Task.isCancelled { return .cancelled }
            transient = await isTransient(error)
        }

        // One store step so edits made while capturing survive; only the capture fields are ours to change.
        // A transient failure keeps what was saved and leaves the item pending.
        let state: CaptureState? = succeeded ? .done : transient ? nil : .failed
        let (newScreenshot, newArchive, newText) = (screenshot, archive, postText)
        guard let saved = try? await store.modify(item.id, {
            if let newScreenshot { $0.screenshot = newScreenshot }
            if let newArchive { $0.archive = newArchive }
            if let newText, ($0.description ?? "").isEmpty { $0.description = newText }
            if let state { $0.capture = state }
        }) else { return .gone }
        try? index.upsert(saved)
        if let archive, let archiveText { try? index.setArchiveText(archiveText, forArchive: archive) }
        if succeeded { await storeFavicon(host: url.host(), iconURL: iconURL) }
        return succeeded ? .done : transient ? .deferred : .failed
    }

    /// The post rendered from its official embed, nil for other links or when the platform does not serve it
    /// (private, deleted, offline): the link is then captured as a page.
    private func socialEmbed(for link: URL) async -> (page: String, text: String?)? {
        guard let embeds else { return nil }
        var url = link
        if SocialEmbed.needsResolving(link) {
            guard let resolved = await resolveRedirects(link) else { return nil }
            url = resolved
        }
        guard let platform = SocialEmbed.platform(of: url), let endpoint = SocialEmbed.endpoint(for: url),
              let data = try? await embeds.fetch(endpoint).data,
              let response = try? SocialEmbed.decode(data)
        else { return nil }
        return (SocialEmbed.page(for: response, platform: platform), SocialEmbed.text(of: response))
    }

    /// The URL a plain request for `url` ends up at after redirects; only the response head is waited for.
    static let followRedirects: @Sendable (URL) async -> URL? = { url in
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (bytes, response) = try? await URLSession(configuration: .ephemeral).bytes(for: request) else {
            return nil
        }
        bytes.task.cancel()
        return response.url
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
