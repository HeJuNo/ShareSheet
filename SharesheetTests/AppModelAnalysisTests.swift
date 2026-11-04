import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Sharesheet
import SharesheetCore

private final class StubTagger: DocumentTagging, @unchecked Sendable {
    let answer: String?
    init(answer: String?) { self.answer = answer }
    var isAvailable: Bool { true }
    func tag(forText text: String, existingTags: [String]) async throws -> String? { answer }
}

/// Never answers until cancelled; reports when a call started.
private final class SleepyTagger: DocumentTagging, @unchecked Sendable {
    var sleep = 30
    private let lock = NSLock()
    private var started = false
    var hasStarted: Bool { lock.withLock { started } }
    var isAvailable: Bool { true }
    func tag(forText text: String, existingTags: [String]) async throws -> String? {
        lock.withLock { started = true }
        try await Task.sleep(for: .seconds(sleep))
        return nil
    }
}

/// Holds every capture until `release()`, then fails it.
private final class GatedCapturer: PageCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var started = false
    var hasStarted: Bool { lock.withLock { started } }
    func release() { lock.withLock { open = true } }

    @MainActor func capture(_ url: URL) async throws -> PageSnapshot {
        lock.withLock { started = true }
        while !lock.withLock({ open }) { try await Task.sleep(for: .milliseconds(10)) }
        throw CaptureError.timeout
    }
}

private struct NoFetch: ResourceFetching {
    func fetch(_ url: URL) async throws -> (data: Data, mimeType: String?) { throw URLError(.badURL) }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AppModelAnalysisTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "AppModelAnalysisTests-\(UUID().uuidString)")!
    }

    private func makePDF(
        in dir: URL, name: String = "doc-\(UUID().uuidString).pdf",
        lines: [String] = ["Rechnung Nummer 4711 Tischlerei Eichenholz", "Hobelbank Leimzwingen Eichenholz Hobelbank"]
    ) throws -> URL {
        let url = dir.appending(path: name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        for (row, line) in lines.enumerated() {
            let string = NSAttributedString(
                string: line, attributes: [kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("Helvetica" as CFString, 14, nil)])
            context.textPosition = CGPoint(x: 40, y: 740 - Double(row) * 24)
            CTLineDraw(CTLineCreateWithAttributedString(string), context)
        }
        context.endPDFPage()
        context.closePDF()
        return url
    }

    private func addPDF(_ env: ModelEnv) async throws -> Item {
        let item = try await env.store.create(
            ItemDraft(type: .document, title: "Doc", fileSource: try makePDF(in: env.base)), in: .unsorted)
        try env.index.upsert(item)
        return item
    }

    private func model(
        _ env: ModelEnv, defaults: UserDefaults, runner: CaptureRunner? = nil, answer: String? = "Rechnung",
        isForeground: @escaping @Sendable () async -> Bool = { true }
    ) -> AppModel {
        let store = env.store
        nonisolated(unsafe) let sharedDefaults = defaults  // UserDefaults is thread-safe
        let analyzer = DocumentAnalyzer(
            store: store, index: env.index, tagger: StubTagger(answer: answer),
            tagMode: { AnalysisSettings.tagMode(sharedDefaults) })
        return AppModel(
            storeFactory: { store }, index: env.index, inbox: env.inbox, runner: runner, analyzer: analyzer,
            defaults: defaults, isForeground: isForeground)
    }

    @Test func refreshStartsAnalysisAndSearchFindsDocumentText() async throws {
        let env = try ModelEnv()
        let item = try await addPDF(env)
        let model = model(env, defaults: makeDefaults())
        await model.refresh()
        await model.analysisFinished()

        #expect(model.analysis(for: item.id)?.keywords.contains { $0.term.lowercased() == "hobelbank" } == true)
        #expect(model.analysis(for: item.id)?.suggestedTag == "Rechnung")
        #expect(model.items(LibraryQuery(text: "Leimzwingen", scope: .all)).map(\.id) == [item.id])
    }

    @Test func acceptingASuggestionAddsTheTagAndClearsIt() async throws {
        let env = try ModelEnv()
        let item = try await addPDF(env)
        let model = model(env, defaults: makeDefaults())
        await model.refresh()
        await model.analysisFinished()
        #expect(model.analysis(for: item.id)?.suggestedTag == "Rechnung")

        try await model.acceptSuggestedTag("Rechnung", for: item.id)

        #expect(try await env.store.item(item.id).tags == ["Rechnung"])
        #expect(model.analysis(for: item.id)?.suggestedTag == nil)
        #expect(model.tags.contains("Rechnung"))
    }

    @Test func dismissingASuggestionClearsIt() async throws {
        let env = try ModelEnv()
        let item = try await addPDF(env)
        let model = model(env, defaults: makeDefaults())
        await model.refresh()
        await model.analysisFinished()

        model.dismissSuggestedTag(for: item.id)

        #expect(model.analysis(for: item.id)?.suggestedTag == nil)
        #expect(model.analysis(for: item.id) != nil)
        #expect(try await env.store.item(item.id).tags.isEmpty)
    }

    @Test func analysisIsSkippedWhenSwitchedOff() async throws {
        let env = try ModelEnv()
        let item = try await addPDF(env)
        let defaults = makeDefaults()
        defaults.set(false, forKey: "analyzeDocuments")
        let model = model(env, defaults: defaults)
        await model.refresh()
        await model.analysisFinished()
        #expect(model.analysis(for: item.id) == nil)

        // Read at run time: switching it on later takes effect without a new model.
        defaults.set(true, forKey: "analyzeDocuments")
        await model.refresh()
        await model.analysisFinished()
        #expect(model.analysis(for: item.id) != nil)
    }

    @Test func analysisWaitsForRunningCapturesAndRunsAfterThem() async throws {
        let env = try ModelEnv()
        let item = try await addPDF(env)
        _ = try await env.store.create(
            ItemDraft(type: .link, url: URL(string: "https://example.com/a")!, title: "A", capture: .pending), in: .unsorted)
        let capturer = GatedCapturer()
        let runner = CaptureRunner(
            store: env.store, index: env.index, capturer: capturer, archiver: HTMLArchiver(fetcher: NoFetch()),
            favicons: FaviconFetcher(fetcher: NoFetch()), attemptMarker: env.base.appending(path: "capture-attempt"))
        let model = model(env, defaults: makeDefaults(), runner: runner)
        await model.refresh()
        try await waitUntil("the capture to start") { capturer.hasStarted }
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.analysis(for: item.id) == nil)

        capturer.release()
        await model.refreshAndCapture()
        await model.analysisFinished()

        #expect(model.analysis(for: item.id) != nil)
    }

    @Test func settingsDefaultsAndInvalidValues() {
        let defaults = makeDefaults()
        #expect(AnalysisSettings.isEnabled(defaults))
        #expect(AnalysisSettings.tagMode(defaults) == .suggest)
        defaults.set("bogus", forKey: "tagMode")
        #expect(AnalysisSettings.tagMode(defaults) == .suggest)
        defaults.set(TagMode.automatic.rawValue, forKey: "tagMode")
        #expect(AnalysisSettings.tagMode(defaults) == .automatic)
        defaults.set(false, forKey: "analyzeDocuments")
        #expect(!AnalysisSettings.isEnabled(defaults))
    }

    @Test func stoppingWaitsForARunningAnalysis() async throws {
        let env = try ModelEnv()
        _ = try await addPDF(env)
        let store = env.store
        let tagger = SleepyTagger()
        let analyzer = DocumentAnalyzer(store: store, index: env.index, tagger: tagger, tagMode: { .suggest })
        let model = AppModel(
            storeFactory: { store }, index: env.index, inbox: env.inbox, runner: nil, analyzer: analyzer,
            defaults: makeDefaults())
        await model.refresh()
        try await waitUntil("the tagger to start") { tagger.hasStarted }
        #expect(model.isAnalyzing)

        await model.stopCaptures()

        #expect(!model.isAnalyzing)
    }

    @Test func acceptingForAVanishedItemClearsItsSuggestion() async throws {
        let env = try ModelEnv()
        let item = try await addPDF(env)
        let model = model(env, defaults: makeDefaults())
        await model.refresh()
        await model.analysisFinished()
        #expect(model.analysis(for: item.id)?.suggestedTag == "Rechnung")
        try FileManager.default.removeItem(at: env.libraryRoot.appending(path: item.id.relativePath))

        await #expect(throws: StoreError.self) { try await model.acceptSuggestedTag("Rechnung", for: item.id) }

        #expect(model.analysis(for: item.id)?.suggestedTag == nil)
    }

    @Test func acceptingUsesTheSpellingOfAnExistingTag() async throws {
        let env = try ModelEnv()
        _ = try await env.store.create(ItemDraft(type: .text, title: "Other", tags: ["Rechnung"]), in: .unsorted)
        let item = try await addPDF(env)
        let model = model(env, defaults: makeDefaults(), answer: "Rechnungen")
        await model.refresh()
        await model.analysisFinished()
        #expect(model.analysis(for: item.id)?.suggestedTag == "Rechnung")  // resolved by the analyzer already
        // A suggestion stored before the user's spelling existed:
        try env.index.setSuggestedTag("Rechnungen", forItem: item.id)

        try await model.acceptSuggestedTag("Rechnungen", for: item.id)

        #expect(try await env.store.item(item.id).tags == ["Rechnung"])
    }

    @Test func stoppingDuringCapturesDoesNotStartAnAnalysis() async throws {
        let env = try ModelEnv()
        let store = env.store
        let tagger = SleepyTagger()
        tagger.sleep = 8
        let analyzer = DocumentAnalyzer(store: store, index: env.index, tagger: tagger, tagMode: { .suggest })
        let capturer = GatedCapturer()
        let runner = CaptureRunner(
            store: store, index: env.index, capturer: capturer, archiver: HTMLArchiver(fetcher: NoFetch()),
            favicons: FaviconFetcher(fetcher: NoFetch()), attemptMarker: env.base.appending(path: "capture-attempt"))
        let model = AppModel(
            storeFactory: { store }, index: env.index, inbox: env.inbox, runner: runner, analyzer: analyzer,
            defaults: makeDefaults())
        await model.refresh()  // nothing to capture or analyze yet: no analysis run is left over
        await model.analysisFinished()
        _ = try await addPDF(env)
        let link = try await store.create(
            ItemDraft(type: .link, url: URL(string: "https://example.com/a")!, title: "A", capture: .pending), in: .unsorted)
        try env.index.upsert(link)
        model.capturePendingNow()
        try await waitUntil("the capture to start") { capturer.hasStarted }
        #expect(!model.isAnalyzing)

        let started = ContinuousClock.now
        await model.stopCaptures()

        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(!model.isAnalyzing)
        #expect(!tagger.hasStarted)
    }

    @Test func aSuggestionForATagTheItemAlreadyHasIsNotShown() {
        let suggestion: String? = "Rechnung"
        #expect(AppModel.visibleSuggestion(suggestion, itemTags: []) == "Rechnung")
        #expect(AppModel.visibleSuggestion(suggestion, itemTags: ["Steuer"]) == "Rechnung")
        #expect(AppModel.visibleSuggestion(suggestion, itemTags: ["rechnung"]) == nil)
        #expect(AppModel.visibleSuggestion(nil, itemTags: []) == nil)
    }

    @Test func noAnalysisRunsInTheBackground() async throws {
        let env = try ModelEnv()
        let item = try await addPDF(env)
        let model = model(env, defaults: makeDefaults(), isForeground: { false })
        await model.refresh()
        await model.analysisFinished()
        #expect(model.analysis(for: item.id) == nil)
        #expect(try env.index.analysisCandidates().map(\.id) == [item.id])
    }

    @Test func refreshAndCaptureDoesNotWaitForAnAnalysis() async throws {
        let env = try ModelEnv()
        _ = try await addPDF(env)
        let store = env.store
        let tagger = SleepyTagger()
        tagger.sleep = 20
        let analyzer = DocumentAnalyzer(store: store, index: env.index, tagger: tagger, tagMode: { .suggest })
        let model = AppModel(
            storeFactory: { store }, index: env.index, inbox: env.inbox, runner: nil, analyzer: analyzer,
            defaults: makeDefaults())
        let started = ContinuousClock.now
        await model.refreshAndCapture()
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(model.isAnalyzing)
        await model.stopCaptures()
    }

    @Test func aFileWithTheNameOfADeletedOneIsAnalyzedAfresh() async throws {
        let env = try ModelEnv()
        let first = try await addPDF(env)
        let model = model(env, defaults: makeDefaults())
        await model.refresh()
        await model.analysisFinished()
        #expect(model.analysis(for: first.id)?.keywords.isEmpty == false)

        try await model.delete(first.id)
        // The freed attachment name is taken over by the next file.
        let dir = env.base.appending(path: "new", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = (try #require(first.file) as NSString).lastPathComponent
        let fresh = try makePDF(in: dir, name: name, lines: ["Quartalsbericht Rentabilitaet Quartalsbericht"])
        let second = try await env.store.create(
            ItemDraft(type: .document, title: "Doc", fileSource: fresh), in: .unsorted)
        try env.index.upsert(second)
        #expect(second.file == first.file)
        #expect(try env.index.analysisCandidates().map(\.id) == [second.id])
        #expect(model.analysis(for: second.id) == nil)
        #expect(try env.index.search(LibraryQuery(text: "Hobelbank", scope: .all)).isEmpty)

        await model.refresh()
        await model.analysisFinished()
        let keywords = try #require(model.analysis(for: second.id)).keywords.map { $0.term.lowercased() }
        #expect(keywords.contains("quartalsbericht"))
        #expect(!keywords.contains("hobelbank"))
    }

    @Test func acceptingATagTheItemHasInAnotherSpellingAddsNothing() async throws {
        let env = try ModelEnv()
        _ = try await env.store.create(ItemDraft(type: .text, title: "Other", tags: ["Rechnung"]), in: .unsorted)
        let created = try await env.store.create(
            ItemDraft(type: .document, title: "Doc", tags: ["rechnung"], fileSource: try makePDF(in: env.base)), in: .unsorted)
        let model = model(env, defaults: makeDefaults())
        await model.refresh()
        try await model.acceptSuggestedTag("Rechnung", for: created.id)
        #expect(try await env.store.item(created.id).tags == ["rechnung"])
    }
}
