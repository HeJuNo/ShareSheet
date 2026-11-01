import Foundation
import Testing
import UIKit
@testable import Sharesheet
import SharesheetCore

private let tinyPNG: Data = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { ctx in
    UIColor.red.setFill()
    ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
}

/// Lets a test hold the fake capturer mid-capture and know when it got there.
private actor Gate {
    private var entered = false
    private var isOpen = false
    private var enterWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() {
        entered = true
        enterWaiters.forEach { $0.resume() }
        enterWaiters = []
    }

    func pass() async {
        enter()
        if isOpen { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enterWaiters.append($0) }
    }

    func open() {
        isOpen = true
        openWaiters.forEach { $0.resume() }
        openWaiters = []
    }
}

private final class FakeCapturer: PageCapturing, @unchecked Sendable {
    enum Behavior {
        case succeed
        case fail(CaptureError)
        /// Waits at the gate, then succeeds.
        case wait(Gate)
        /// Signals the gate, then sleeps until cancelled.
        case hangUntilCancelled(Gate)
    }

    private let lock = NSLock()
    private var _captured: [URL] = []
    private let behavior: Behavior
    private let failing: Set<URL>

    init(_ behavior: Behavior = .succeed, failing: Set<URL> = []) {
        self.behavior = behavior
        self.failing = failing
    }

    convenience init(error: CaptureError) { self.init(.fail(error)) }

    var captured: [URL] { lock.withLock { _captured } }

    @MainActor func capture(_ url: URL) async throws -> PageSnapshot {
        lock.withLock { _captured.append(url) }
        if failing.contains(url) { throw CaptureError.timeout }
        switch behavior {
        case .succeed: break
        case .fail(let error): throw error
        case .wait(let gate): await gate.pass()
        case .hangUntilCancelled(let gate):
            await gate.enter()
            try await Task.sleep(for: .seconds(600))
        }
        return PageSnapshot(
            png: tinyPNG, domHTML: "<html><body><p>lorem ipsum</p></body></html>", finalURL: url,
            iconURL: URL(string: "https://example.com/icon.png"), truncated: false)
    }
}

private struct StubFetcher: ResourceFetching {
    func fetch(_ url: URL) async throws -> (data: Data, mimeType: String?) { (tinyPNG, "image/png") }
}

private struct Env {
    let root: URL
    let store: FolderItemStore
    let index: LibraryIndex

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "CaptureRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = FolderItemStore(root: root)
        index = try LibraryIndex(path: root.appending(path: "index.sqlite"))
    }

    var marker: URL { root.appending(path: "capture-attempt") }

    func runner(_ capturer: FakeCapturer, isForeground: Bool = true) -> CaptureRunner {
        CaptureRunner(
            store: store, index: index, capturer: capturer,
            archiver: HTMLArchiver(fetcher: StubFetcher()), favicons: FaviconFetcher(fetcher: StubFetcher()),
            attemptMarker: marker, isForeground: { isForeground })
    }

    func makeItem(
        _ title: String, capture: CaptureState?, created: Date = Date(), indexed: Bool = true,
        url: URL? = nil
    ) async throws -> Item {
        let item = try await store.create(
            ItemDraft(type: .link, url: url ?? URL(string: "https://example.com/\(title)"), title: title,
                      created: created, capture: capture),
            in: .unsorted)
        if indexed { try index.upsert(item) }
        return item
    }
}

struct CaptureRunnerTests {
    @Test func runnerMarksFailedOnTimeout() async throws {
        let env = try Env()
        let item = try await env.makeItem("slow", capture: .pending)
        let capturer = FakeCapturer(error: .timeout)

        let result = await env.runner(capturer).runPending()

        #expect(result.done == 0)
        #expect(result.failed == 1)
        #expect(try await env.store.item(item.id).capture == .failed)
        #expect(try env.index.search(LibraryQuery(scope: .all)).first?.capture == .failed)
    }

    @Test func runnerWritesScreenshotArchiveAndText() async throws {
        let env = try Env()
        let item = try await env.makeItem("page", capture: .pending)

        let result = await env.runner(FakeCapturer()).runPending()

        #expect(result.done == 1)
        #expect(result.failed == 0)
        let saved = try await env.store.item(item.id)
        #expect(saved.capture == .done)
        let screenshot = try #require(saved.screenshot)
        let archive = try #require(saved.archive)
        #expect(screenshot.hasPrefix("_attachments/"))
        #expect(archive.hasPrefix("_attachments/"))
        #expect(screenshot.hasSuffix(".png"))
        #expect(archive.hasSuffix(".html"))
        #expect(FileManager.default.fileExists(atPath: try await env.store.attachmentURL(screenshot).path))
        #expect(FileManager.default.fileExists(atPath: try await env.store.attachmentURL(archive).path))
        let hits = try env.index.search(LibraryQuery(text: "lorem", scope: .all))
        #expect(hits.map(\.id) == [item.id])
        #expect(try env.index.favicon(host: "example.com") != nil)
    }

    @Test func runnerSkipsNonPending() async throws {
        let env = try Env()
        _ = try await env.makeItem("none", capture: nil)
        _ = try await env.makeItem("done", capture: .done)
        let pending = try await env.makeItem("pending", capture: .pending)
        let capturer = FakeCapturer()

        let result = await env.runner(capturer).runPending()

        #expect(result.done == 1)
        #expect(capturer.captured == [pending.url])
    }

    @Test func runnerProcessesOldestFirstWithLimit() async throws {
        let env = try Env()
        let now = Date()
        let newer = try await env.makeItem("newer", capture: .pending, created: now)
        let older = try await env.makeItem("older", capture: .pending, created: now.addingTimeInterval(-60))
        let capturer = FakeCapturer()

        let result = await env.runner(capturer).runPending(limit: 1)

        #expect(result.done == 1)
        #expect(capturer.captured == [older.url])
        #expect(try await env.store.item(newer.id).capture == .pending)
    }

    @Test func captureRetriesFailedItem() async throws {
        let env = try Env()
        let item = try await env.makeItem("retry", capture: .failed)

        await env.runner(FakeCapturer()).capture(item.id)

        #expect(try await env.store.item(item.id).capture == .done)
    }

    @Test func concurrentRunsCaptureEachItemOnce() async throws {
        let env = try Env()
        let item = try await env.makeItem("once", capture: .pending)
        let capturer = FakeCapturer()
        let runner = env.runner(capturer)

        async let first = runner.runPending()
        async let second = runner.runPending()
        let results = await [first, second]

        #expect(results.map(\.done).reduce(0, +) == 1)
        #expect(capturer.captured == [item.url])
    }

    @Test func captureIgnoresItemWithoutURL() async throws {
        let env = try Env()
        let note = try await env.store.create(ItemDraft(type: .text, title: "note", content: "hello"), in: .unsorted)
        let capturer = FakeCapturer()

        await env.runner(capturer).capture(note.id)

        #expect(capturer.captured.isEmpty)
        #expect(try await env.store.item(note.id).capture == nil)
    }

    @Test func runnerContinuesAfterTimeout() async throws {
        let env = try Env()
        let now = Date()
        let slow = try await env.makeItem("slow", capture: .pending, created: now.addingTimeInterval(-60))
        let fast = try await env.makeItem("fast", capture: .pending, created: now)
        let capturer = FakeCapturer(failing: [try #require(slow.url)])

        let result = await env.runner(capturer).runPending()

        #expect(result.done == 1)
        #expect(result.failed == 1)
        #expect(capturer.captured == [slow.url, fast.url])
        #expect(try await env.store.item(slow.id).capture == .failed)
        #expect(try await env.store.item(fast.id).capture == .done)
    }

    @Test func cancelledRunLeavesItemsPending() async throws {
        let env = try Env()
        let now = Date()
        let first = try await env.makeItem("first", capture: .pending, created: now.addingTimeInterval(-60))
        let second = try await env.makeItem("second", capture: .pending, created: now)
        let gate = Gate()
        let capturer = FakeCapturer(.hangUntilCancelled(gate))
        let runner = env.runner(capturer)

        let run = Task { await runner.runPending() }
        await gate.waitUntilEntered()
        run.cancel()
        let result = await run.value

        #expect(result.done == 0)
        #expect(result.failed == 0)
        #expect(capturer.captured == [first.url])
        #expect(try await env.store.item(first.id).capture == .pending)
        #expect(try await env.store.item(second.id).capture == .pending)
        #expect(try env.index.search(LibraryQuery(scope: .all)).allSatisfy { $0.capture == .pending })
    }

    @Test func editsMadeDuringCaptureSurvive() async throws {
        let env = try Env()
        let item = try await env.makeItem("edited", capture: .pending)
        let gate = Gate()
        let runner = env.runner(FakeCapturer(.wait(gate)))

        let run = Task { await runner.runPending() }
        await gate.waitUntilEntered()
        var edited = try await env.store.item(item.id)
        edited.note = "written while capturing"
        edited.tags = ["kept"]
        _ = try await env.store.update(edited)
        await gate.open()
        let result = await run.value

        #expect(result.done == 1)
        let saved = try await env.store.item(item.id)
        #expect(saved.note == "written while capturing")
        #expect(saved.tags == ["kept"])
        #expect(saved.capture == .done)
        #expect(saved.screenshot != nil)
        #expect(saved.archive != nil)
    }

    @Test func itemDeletedDuringCaptureIsNotIndexed() async throws {
        let env = try Env()
        let item = try await env.makeItem("deleted", capture: .pending, indexed: false)
        let gate = Gate()
        let runner = env.runner(FakeCapturer(.wait(gate)))

        let run = Task { await runner.runPending() }
        await gate.waitUntilEntered()
        try await env.store.delete(item.id)
        await gate.open()
        let result = await run.value

        #expect(result.done == 0)
        #expect(try env.index.search(LibraryQuery(scope: .all)).contains { $0.id == item.id } == false)
        #expect(try await env.store.listItems().contains { $0.id == item.id } == false)
    }

    // MARK: Crash protection

    @Test func anAttemptLeftByACrashMarksThatItemFailed() async throws {
        let env = try Env()
        let crashed = try await env.makeItem("crashed", capture: .pending, created: Date().addingTimeInterval(-60))
        let next = try await env.makeItem("next", capture: .pending)
        try Data(crashed.id.relativePath.utf8).write(to: env.marker)
        let capturer = FakeCapturer()

        let result = await env.runner(capturer).runPending()

        #expect(try await env.store.item(crashed.id).capture == .failed)
        #expect(try env.index.search(LibraryQuery(scope: .all)).first { $0.id == crashed.id }?.capture == .failed)
        #expect(capturer.captured == [next.url])
        #expect(result.done == 1)
        #expect(!FileManager.default.fileExists(atPath: env.marker.path))
    }

    @Test func theAttemptIsRecordedWhileCapturingAndClearedAfter() async throws {
        let env = try Env()
        let item = try await env.makeItem("page", capture: .pending)
        let gate = Gate()
        let runner = env.runner(FakeCapturer(.wait(gate)))

        let run = Task { await runner.runPending() }
        await gate.waitUntilEntered()
        let recorded = try? String(contentsOf: env.marker, encoding: .utf8)
        await gate.open()
        _ = await run.value

        #expect(recorded == item.id.relativePath)
        #expect(!FileManager.default.fileExists(atPath: env.marker.path))
    }

    @Test func aCancelledCaptureClearsTheAttempt() async throws {
        let env = try Env()
        let item = try await env.makeItem("hang", capture: .pending)
        let gate = Gate()
        let runner = env.runner(FakeCapturer(.hangUntilCancelled(gate)))

        let run = Task { await runner.runPending() }
        await gate.waitUntilEntered()
        run.cancel()
        _ = await run.value

        #expect(!FileManager.default.fileExists(atPath: env.marker.path))
        #expect(try await env.store.item(item.id).capture == .pending)
    }

    @Test func anAttemptForAFinishedItemChangesNothing() async throws {
        let env = try Env()
        let done = try await env.makeItem("done", capture: .done)
        try Data(done.id.relativePath.utf8).write(to: env.marker)

        _ = await env.runner(FakeCapturer()).runPending()

        #expect(try await env.store.item(done.id).capture == .done)
        #expect(!FileManager.default.fileExists(atPath: env.marker.path))
    }

    // MARK: Transient failures

    @Test(arguments: [
        NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
        NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff, NSURLErrorCannotFindHost,
        NSURLErrorCannotConnectToHost,
    ])
    func networkErrorsLeaveTheItemPending(code: Int) async throws {
        let env = try Env()
        let item = try await env.makeItem("offline", capture: .pending)

        let result = await env.runner(FakeCapturer(error: .network(code))).runPending()

        #expect(result.done == 0 && result.failed == 0)
        #expect(try await env.store.item(item.id).capture == .pending)
    }

    @Test func otherLoadErrorsStillFail() async throws {
        let env = try Env()
        let item = try await env.makeItem("bad", capture: .pending)

        _ = await env.runner(FakeCapturer(error: .network(NSURLErrorBadServerResponse))).runPending()

        #expect(try await env.store.item(item.id).capture == .failed)
    }

    @Test func aTimeoutInTheBackgroundLeavesTheItemPending() async throws {
        let env = try Env()
        let item = try await env.makeItem("slow", capture: .pending)

        let result = await env.runner(FakeCapturer(error: .timeout), isForeground: false).runPending()

        #expect(result.failed == 0)
        #expect(try await env.store.item(item.id).capture == .pending)
    }

    // MARK: Web pages only

    @Test func pendingItemsWithoutAWebURLAreNotCaptured() async throws {
        let env = try Env()
        let ftp = try await env.makeItem("ftp", capture: .pending, url: URL(string: "ftp://example.com/file")!)
        let mail = try await env.makeItem("mail", capture: .failed, url: URL(string: "mailto:a@example.com")!)
        let capturer = FakeCapturer()
        let runner = env.runner(capturer)

        let result = await runner.runPending()
        await runner.capture(mail.id)

        #expect(capturer.captured.isEmpty)
        #expect(result.done == 0 && result.failed == 0)
        #expect(try await env.store.item(ftp.id).capture == nil)
        #expect(try await env.store.item(mail.id).capture == nil)
        #expect(try env.index.search(LibraryQuery(scope: .all)).first { $0.id == ftp.id }?.capture == nil)
    }
}
