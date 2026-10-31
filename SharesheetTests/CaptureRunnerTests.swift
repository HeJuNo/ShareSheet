import Foundation
import Testing
import UIKit
@testable import Sharesheet
import SharesheetCore

private let tinyPNG: Data = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { ctx in
    UIColor.red.setFill()
    ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
}

private final class FakeCapturer: PageCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var _captured: [URL] = []
    let error: CaptureError?

    init(error: CaptureError? = nil) { self.error = error }

    var captured: [URL] { lock.withLock { _captured } }

    @MainActor func capture(_ url: URL) async throws -> PageSnapshot {
        lock.withLock { _captured.append(url) }
        if let error { throw error }
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

    func runner(_ capturer: FakeCapturer) -> CaptureRunner {
        CaptureRunner(
            store: store, index: index, capturer: capturer,
            archiver: HTMLArchiver(fetcher: StubFetcher()), favicons: FaviconFetcher(fetcher: StubFetcher()))
    }

    func makeItem(_ title: String, capture: CaptureState?, created: Date = Date()) async throws -> Item {
        let item = try await store.create(
            ItemDraft(type: .link, url: URL(string: "https://example.com/\(title)"), title: title,
                      created: created, capture: capture),
            in: .unsorted)
        try index.upsert(item)
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
}
