import Testing
import Foundation
@testable import SharesheetCore

/// A capture finishing after each of the importer's reads, each with a new screenshot; the last one must survive.
private final class CaptureLands: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let base: any ItemStore
    init(on base: any ItemStore) { self.base = base }

    var lastScreenshot: String? { lock.withLock { count == 0 ? nil : "_attachments/shot-\(count).png" } }

    func callAsFunction(_ id: ItemID) async throws {
        let shot = lock.withLock { () -> String in
            count += 1
            return "_attachments/shot-\(count).png"
        }
        _ = try await base.modify(id) {
            $0.screenshot = shot
            $0.capture = .done
        }
    }
}

@Test func modifiesThroughTwoStoresOnOneLibraryAllApply() async throws {
    let (first, root) = try makeStore()
    let second = FolderItemStore(root: root)
    let item = try await first.create(.fixture(), in: .unsorted)
    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0..<40 {
            let store = index.isMultiple(of: 2) ? first : second
            group.addTask { _ = try await store.modify(item.id) { $0.tags.append("t\(index)") } }
        }
        try await group.waitForAll()
    }
    #expect(Set(try await first.item(item.id).tags) == Set((0..<40).map { "t\($0)" }))
}

@Test func reshareKeepsACaptureWrittenMeanwhile() async throws {
    let inbox = Inbox(root: try makeTempDirectory())
    let (base, _) = try makeStore()
    let existing = try await base.create(.fixture(capture: .pending), in: .unsorted)
    try inbox.enqueue(.fixture(entries: [.fixture(highlight: "h")], existingItem: existing.id), files: [:])
    let lands = CaptureLands(on: base)
    let store = AfterReadStore(base: base, afterRead: { try await lands($0) })
    let report = await InboxImporter(inbox: inbox, store: store).importAll()
    #expect(report.failed == 0)
    let saved = try await base.item(existing.id)
    #expect(saved.highlights == ["h"])
    #expect(lands.lastScreenshot != nil)
    #expect(saved.screenshot == lands.lastScreenshot && saved.capture == .done)
}

@Test func mergeKeepsACaptureWrittenMeanwhile() async throws {
    let inbox = Inbox(root: try makeTempDirectory())
    let (base, _) = try makeStore()
    let existing = try await base.create(.fixture(capture: .pending), in: .unsorted)
    try inbox.enqueue(.fixture(entries: [.fixture(highlight: "h")], tags: ["new"]), files: [:])
    let lands = CaptureLands(on: base)
    let store = AfterReadStore(base: base, afterRead: { try await lands($0) })
    let report = await InboxImporter(inbox: inbox, store: store).importAll()
    #expect(report.failed == 0)
    let saved = try await base.item(existing.id)
    #expect(saved.highlights == ["h"] && saved.tags == ["new"])
    #expect(lands.lastScreenshot != nil)
    #expect(saved.screenshot == lands.lastScreenshot && saved.capture == .done)
}
