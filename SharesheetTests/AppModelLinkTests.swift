import Foundation
import Observation
import Testing
@testable import Sharesheet
import SharesheetCore

@MainActor
struct AppModelLinkTests {
    private final class Box: @unchecked Sendable {
        var changed = false
    }

    private final class Checker: @unchecked Sendable {
        private let lock = NSLock()
        private var _result: LinkCheckResult
        private var _calls = 0

        init(_ result: LinkCheckResult) { self._result = result }

        var result: LinkCheckResult {
            get { lock.withLock { _result } }
            set { lock.withLock { _result = newValue } }
        }
        var calls: Int { lock.withLock { _calls } }

        func check(_ url: URL) async -> LinkCheckResult {
            lock.withLock { _calls += 1 }
            return result
        }
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "AppModelLinkTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private final class SlowChecker: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int { lock.withLock { _calls } }

        func check(_ url: URL) async -> LinkCheckResult {
            lock.withLock { _calls += 1 }
            try? await Task.sleep(for: .milliseconds(200))
            return .init(status: .broken, httpStatus: 404)
        }
    }

    private func model(_ env: ModelEnv, _ checker: Checker, defaults: UserDefaults = .standard) -> AppModel {
        AppModel(
            storeFactory: { env.store }, index: env.index, inbox: env.inbox, runner: nil,
            linkCheck: { await checker.check($0) }, defaults: defaults)
    }

    @Test func checkLinksRecordsBrokenOnes() async throws {
        let env = try ModelEnv()
        let url = URL(string: "https://broken.test/1")!
        _ = try await env.store.create(ItemDraft(type: .link, url: url, title: "Broken"), in: .unsorted)
        let checker = Checker(.init(status: .broken, httpStatus: 404))
        let model = model(env, checker)
        await model.refresh()

        let checked = await model.checkLinks(limit: 25, olderThan: 0, timeBudget: 60)

        #expect(checked == 1)
        #expect(model.counts.brokenLinks == 1)
        #expect(model.brokenLinks().map(\.item.title) == ["Broken"])
        #expect(model.brokenLinks().first?.check.httpStatus == 404)
    }

    @Test func backgroundCheckRunsAtMostOnceADay() async throws {
        let env = try ModelEnv()
        _ = try await env.store.create(
            ItemDraft(type: .link, url: URL(string: "https://broken.test/2")!, title: "Broken"), in: .unsorted)
        let checker = Checker(.init(status: .broken, httpStatus: 404))
        let model = model(env, checker, defaults: makeDefaults())
        await model.refresh()

        #expect(await model.checkLinksInBackground() == 1)
        #expect(await model.checkLinksInBackground() == 0)
        #expect(checker.calls == 1)
    }

    @Test func recheckingAWorkingLinkRemovesIt() async throws {
        let env = try ModelEnv()
        let url = URL(string: "https://broken.test/3")!
        _ = try await env.store.create(ItemDraft(type: .link, url: url, title: "Broken"), in: .unsorted)
        let checker = Checker(.init(status: .broken, httpStatus: 404))
        let model = model(env, checker)
        await model.refresh()
        await model.checkLinks(limit: 25, olderThan: 0, timeBudget: 60)
        #expect(model.counts.brokenLinks == 1)

        checker.result = .init(status: .ok, httpStatus: 200)
        await model.recheckLink(url)

        #expect(model.counts.brokenLinks == 0)
        #expect(model.brokenLinks().isEmpty)
    }

    @Test func brokenLinksObservesTheRevision() async throws {
        let env = try ModelEnv()
        _ = try await env.store.create(
            ItemDraft(type: .link, url: URL(string: "https://broken.test/observe")!, title: "A"),
            in: .unsorted)
        let model = model(env, Checker(.init(status: .broken, httpStatus: 404)))
        await model.refresh()
        let box = Box()
        withObservationTracking {
            _ = model.brokenLinks()
        } onChange: {
            box.changed = true
        }

        let item = try #require(model.items(LibraryQuery(scope: .all)).first)
        try await model.toggleFavorite(item)

        #expect(box.changed)
    }

    @Test func aCancelledBackgroundRunRecordsNothingAndKeepsTheDayOpen() async throws {
        let env = try ModelEnv()
        _ = try await env.store.create(
            ItemDraft(type: .link, url: URL(string: "https://broken.test/cancel")!, title: "Broken"),
            in: .unsorted)
        let checker = SlowChecker()
        let defaults = makeDefaults()
        let model = AppModel(
            storeFactory: { env.store }, index: env.index, inbox: env.inbox, runner: nil,
            linkCheck: { await checker.check($0) }, defaults: defaults)
        await model.refresh()

        let task = Task { await model.checkLinksInBackground() }
        try await waitUntil("check started") { checker.calls > 0 }
        task.cancel()
        _ = await task.value

        #expect(model.counts.brokenLinks == 0)
        #expect(defaults.object(forKey: "linkCheck.lastRun") == nil)
    }
}
