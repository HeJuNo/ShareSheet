import Foundation
import Testing
@testable import Sharesheet
import SharesheetCore

/// Never finishes a capture until cancelled; reports when one started.
private final class HangingCapturer: PageCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    var hasStarted: Bool { lock.withLock { started } }

    @MainActor func capture(_ url: URL) async throws -> PageSnapshot {
        lock.withLock { started = true }
        try await Task.sleep(for: .seconds(600))
        throw CaptureError.timeout
    }
}

@MainActor
struct AppModelCaptureTests {
    @Test func leavingTheForegroundStopsTheCaptureAndKeepsTheItemPending() async throws {
        let env = try ModelEnv()
        let marker = env.base.appending(path: "capture-attempt")
        let capturer = HangingCapturer()
        let runner = CaptureRunner(
            store: env.store, index: env.index, capturer: capturer, archiver: HTMLArchiver(fetcher: NoFetch()),
            favicons: FaviconFetcher(fetcher: NoFetch()), attemptMarker: marker)
        let item = try await env.store.create(
            ItemDraft(type: .link, url: URL(string: "https://example.com/a")!, title: "A", capture: .pending),
            in: .unsorted)
        let store = env.store
        let model = AppModel(storeFactory: { store }, index: env.index, inbox: env.inbox, runner: runner)
        await model.refresh()
        while !capturer.hasStarted { try await Task.sleep(for: .milliseconds(10)) }

        await model.stopCaptures()

        #expect(try await env.store.item(item.id).capture == .pending)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}
