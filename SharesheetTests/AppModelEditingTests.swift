import Foundation
import Testing
@testable import Sharesheet
import SharesheetCore

@MainActor
struct AppModelEditingTests {
    @Test func anItemMovedByARuleIsStillReachableByItsOldID() async throws {
        let env = try ModelEnv()
        let created = try await env.store.create(ItemDraft(type: .text, title: "Receipt"), in: .unsorted)
        let redirects = MoveRedirects()
        let model = env.model(redirects: redirects)
        await model.refresh()
        let moved = try await env.store.move(created.id, to: CollectionPath(components: ["Tech"]))
        redirects.record(from: created.id, to: moved.id)

        var item = try await model.loadItem(created.id)
        #expect(item.id == moved.id)
        item.note = "edited"
        let saved = try await model.save(Item(id: created.id, type: item.type, title: item.title, tags: ["x"], created: item.created, note: "edited"))
        #expect(saved.id == moved.id && saved.note == "edited")
        let again = try await model.move(created.id, to: CollectionPath(components: ["Other"]))
        #expect(again.collection == CollectionPath(components: ["Other"]))
        try await model.delete(again)  // after its own move the screen uses the id it got back
        #expect(try await env.store.listItems().isEmpty)
    }

    @Test func aHandSetDateIsSavedAndAnUntouchedOneIsNot() async throws {
        let env = try ModelEnv()
        let created = try await env.store.create(ItemDraft(type: .text, title: "Receipt"), in: .unsorted)
        let model = env.model()
        await model.refresh()
        let original = created.created
        let byHand = Date(timeIntervalSince1970: 1_700_000_000)

        var stale = try await model.loadItem(created.id)
        stale.created = byHand  // changed, but not marked: another writer's date must not be overwritten
        stale.note = "n"
        _ = try await model.save(stale)
        #expect(try await env.store.item(created.id).created == original)

        stale.createdManual = true
        let saved = try await model.save(stale)
        #expect(saved.created == byHand && saved.createdManual)
        #expect(try await env.store.item(created.id).created == byHand)
        #expect(model.items(LibraryQuery(scope: .all)).first?.created == byHand)
    }

    @Test func redirectsFollowSeveralMovesAndStopAtLoops() {
        let redirects = MoveRedirects()
        let a = ItemID(relativePath: "A/1.md"), b = ItemID(relativePath: "B/1.md"), c = ItemID(relativePath: "C/1.md")
        redirects.record(from: a, to: b)
        redirects.record(from: b, to: c)
        #expect(redirects.current(a) == c)
        redirects.record(from: c, to: a)  // a loop must not hang
        _ = redirects.current(a)
        #expect(redirects.current(ItemID(relativePath: "Z/9.md")) == ItemID(relativePath: "Z/9.md"))
    }

    @Test func editingTagsWritesFileAndIndex() async throws {
        let env = try ModelEnv()
        let created = try await env.store.create(ItemDraft(type: .text, title: "Receipt"), in: .unsorted)
        let model = env.model()
        await model.refresh()

        var item = try await model.loadItem(created.id)
        item.tags = ["groceries", "billa"]
        item.note = "Weekly shop"
        _ = try await model.save(item)

        let markdown = try String(contentsOf: env.libraryRoot.appending(path: created.id.relativePath), encoding: .utf8)
        #expect(markdown.contains("groceries"))
        #expect(markdown.contains("billa"))
        #expect(markdown.contains("Weekly shop"))
        #expect(model.items(LibraryQuery(scope: .all, tags: ["billa"])).map(\.title) == ["Receipt"])
        #expect(model.tags.contains("groceries"))
    }

    @Test func saveKeepsChangesMadeMeanwhile() async throws {
        let env = try ModelEnv()
        let created = try await env.store.create(
            ItemDraft(type: .link, url: URL(string: "https://example.com")!, title: "Page", capture: .pending),
            in: .unsorted)
        let model = env.model()
        await model.refresh()
        var stale = try await model.loadItem(created.id)

        var captured = try await env.store.item(created.id)
        captured.screenshot = "_attachments/page.png"
        captured.capture = .done
        _ = try await env.store.update(captured)
        stale.tags = ["web"]
        stale.favorite = true
        let saved = try await model.save(stale)

        let onDisk = try await env.store.item(created.id)
        #expect(onDisk.tags == ["web"])
        #expect(onDisk.favorite)
        #expect(onDisk.screenshot == "_attachments/page.png")
        #expect(onDisk.capture == .done)
        #expect(saved == onDisk)
    }

    @Test func saveIsAtomicAgainstACaptureWrite() async throws {
        let env = try ModelEnv()
        let created = try await env.store.create(
            ItemDraft(type: .link, url: URL(string: "https://example.com")!, title: "Page", capture: .pending),
            in: .unsorted)
        // Any read outside the store's atomic step is followed by a capture write, as if the runner
        // finished right then. A non-atomic save would then overwrite the capture result.
        let store = CaptureAfterReadStore(base: env.store)
        let model = AppModel(storeFactory: { store }, index: env.index, inbox: env.inbox, runner: nil)
        await model.refresh()
        var edited = try await env.store.item(created.id)
        edited.tags = ["web"]

        _ = try await model.save(edited)

        let onDisk = try await env.store.item(created.id)
        #expect(onDisk.tags == ["web"])
        if store.flag.fired {
            #expect(onDisk.screenshot == "_attachments/shot.png")
            #expect(onDisk.capture == .done)
        }
    }

    @Test func savingADeletedItemThrowsNotFound() async throws {
        let env = try ModelEnv()
        let created = try await env.store.create(ItemDraft(type: .text, title: "Gone"), in: .unsorted)
        let model = env.model()
        await model.refresh()
        var item = try await model.loadItem(created.id)
        try FileManager.default.removeItem(at: env.libraryRoot.appending(path: created.id.relativePath))
        item.title = "Renamed"

        await #expect(throws: StoreError.notFound(created.id.relativePath)) { try await model.save(item) }
    }

    @Test func moveUpdatesCounts() async throws {
        let env = try ModelEnv()
        let created = try await env.store.create(ItemDraft(type: .text, title: "Receipt"), in: .unsorted)
        let model = env.model()
        await model.refresh()
        let billa = try await model.createCollection(named: "Billa", in: .root)

        let newID = try await model.move(created.id, to: billa)

        #expect(newID.collection == billa)
        #expect(model.counts.all == 1)
        #expect(model.counts.unsorted == 0)
        #expect(model.counts.byCollection[billa] == 1)
        #expect(model.items(LibraryQuery(scope: .collection(billa))).map(\.id) == [newID])
        #expect(FileManager.default.fileExists(atPath: env.libraryRoot.appending(path: newID.relativePath).path))
    }

    @Test func deleteCollectionMovingItemsToUnsorted() async throws {
        let env = try ModelEnv()
        let model = env.model()
        await model.refresh()
        let billa = try await model.createCollection(named: "Billa", in: .root)
        _ = try await env.store.create(ItemDraft(type: .text, title: "Receipt"), in: billa)
        await model.refresh()

        await #expect(throws: StoreError.collectionNotEmpty) {
            try await model.deleteCollection(billa, moveItemsToUnsorted: false)
        }
        #expect(model.collections.contains(billa))

        try await model.deleteCollection(billa, moveItemsToUnsorted: true)

        #expect(!model.collections.contains(billa))
        #expect(model.counts.unsorted == 1)
        #expect(model.counts.byCollection[billa] == nil)
        #expect(model.items(LibraryQuery(scope: .unsorted)).map(\.title) == ["Receipt"])
    }

    @Test func deleteEmptyCollection() async throws {
        let env = try ModelEnv()
        let model = env.model()
        await model.refresh()
        let empty = try await model.createCollection(named: "Empty", in: .root)

        try await model.deleteCollection(empty, moveItemsToUnsorted: false)

        #expect(!model.collections.contains(empty))
    }

    @Test func missingAttachmentReturnsNil() async throws {
        let env = try ModelEnv()
        let model = env.model()
        await model.refresh()
        let source = env.base.appending(path: "shot.png")
        try Data([1, 2, 3]).write(to: source)
        let present = try await env.store.addAttachment(from: source, preferredName: "shot.png")

        #expect(await model.attachmentURL("_attachments/missing.png") == nil)
        #expect(await model.attachmentURL(present) != nil)
    }
}

/// Wraps a store; right after each `item(_:)` read it writes capture results to that item.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var fired: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private struct CaptureAfterReadStore: ItemStore {
    let base: any ItemStore
    let flag = Flag()
    func listItems() async throws -> [Item] { try await base.listItems() }
    func item(_ id: ItemID) async throws -> Item {
        let item = try await base.item(id)
        flag.fired = true
        _ = try await base.modify(id) {
            $0.screenshot = "_attachments/shot.png"
            $0.capture = .done
        }
        return item
    }
    func findItem(url: URL) async throws -> Item? { try await base.findItem(url: url) }
    func create(
        _ draft: ItemDraft, in collection: CollectionPath, willWrite: @Sendable (ItemID) throws -> Void
    ) async throws -> Item {
        try await base.create(draft, in: collection, willWrite: willWrite)
    }
    func update(_ item: Item) async throws -> Item { try await base.update(item) }
    func modify(_ id: ItemID, _ transform: @Sendable (inout Item) throws -> Void) async throws -> Item {
        try await base.modify(id, transform)
    }
    func move(_ id: ItemID, to collection: CollectionPath) async throws -> Item {
        try await base.move(id, to: collection)
    }
    func delete(_ id: ItemID) async throws { try await base.delete(id) }
    func addAttachment(from source: URL, preferredName: String) async throws -> String {
        try await base.addAttachment(from: source, preferredName: preferredName)
    }
    func attachmentURL(_ relativePath: String) async throws -> URL { try await base.attachmentURL(relativePath) }
    func collections() async throws -> [CollectionPath] { try await base.collections() }
    func createCollection(named name: String, in parent: CollectionPath) async throws -> CollectionPath {
        try await base.createCollection(named: name, in: parent)
    }
    func deleteCollection(_ path: CollectionPath, moveItemsTo destination: CollectionPath?) async throws {
        try await base.deleteCollection(path, moveItemsTo: destination)
    }
    func changes() -> AsyncStream<Void> { base.changes() }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AppModelTitleAndSumsTests {
    @Test func aHandSetTitleIsWrittenAndMarked() async throws {
        let env = try ModelEnv()
        let model = env.model()
        await model.refresh()
        let item = try await env.store.create(ItemDraft(type: .text, title: "Auto", content: "x"), in: .unsorted)
        var edited = item
        edited.title = "Mein Titel"
        edited.titleManual = true
        let saved = try await model.save(edited)
        #expect(saved.title == "Mein Titel" && saved.titleManual)
    }

    @Test func theModelSumsNumberFieldsOfTheListedItems() async throws {
        let env = try ModelEnv()
        let model = env.model()
        await model.refresh()
        for amount in [4.5, 5.5] {
            var item = try await env.store.create(ItemDraft(type: .text, title: "R", content: "x"), in: .unsorted)
            item = try await env.store.modify(item.id) { $0.fields = ["Betrag": .number(amount)] }
            try env.index.upsert(item)
        }
        #expect(model.fieldStats(LibraryQuery(scope: .all)) == [FieldStat(name: "Betrag", aggregate: .sum, value: 10, count: 2)])
    }

    @Test func theRulesChooseWhichAggregateAListShows() async throws {
        let env = try ModelEnv()
        try RuleFile.save(RuleSet(rules: [Rule(
            id: "r", name: "r", enabled: true, conditions: [RuleCondition(field: .text, op: .contains, value: "x")],
            actions: [.setField(name: "Betrag", pattern: "Summe {Zahl}", aggregate: .max)])]), to: env.libraryRoot)
        let model = env.model(rulesRoot: env.libraryRoot)
        await model.refresh()
        for amount in [4.5, 5.5] {
            var item = try await env.store.create(ItemDraft(type: .text, title: "R", content: "x"), in: .unsorted)
            item = try await env.store.modify(item.id) { $0.fields = ["Betrag": .number(amount), "Rest": .text("x")] }
            try env.index.upsert(item)
        }
        #expect(model.fieldStats(LibraryQuery(scope: .all)) == [FieldStat(name: "Betrag", aggregate: .max, value: 5.5, count: 2)])
    }

    @Test func editingAFieldMarksItAsHandSetAndDeletingKeepsRulesFromSettingItAgain() async throws {
        let env = try ModelEnv()
        let model = env.model()
        await model.refresh()
        var item = try await env.store.create(ItemDraft(type: .text, title: "R", content: "x"), in: .unsorted)
        item = try await env.store.modify(item.id) { $0.fields = ["Betrag": .number(1), "Menge": .number(2)] }
        try env.index.upsert(item)

        let edited = try await model.setField(item.id, name: "Betrag", value: .number(7))
        #expect(edited.fields["Betrag"] == .number(7) && edited.fieldsManual == ["Betrag"])
        #expect(model.fieldStats(LibraryQuery(scope: .all)).first { $0.name == "Betrag" }?.value == 7)

        let deleted = try await model.deleteField(item.id, name: "Menge")
        #expect(deleted.fields["Menge"] == nil && deleted.fieldsDeleted == ["Menge"])
        #expect(model.fieldStats(LibraryQuery(scope: .all)).map(\.name) == ["Betrag"])
        let reloaded = try await env.store.item(item.id)
        #expect(reloaded.fieldsManual == ["Betrag"] && reloaded.fieldsDeleted == ["Menge"])

        let again = try await model.setField(item.id, name: "Menge", value: .number(3))
        #expect(again.fieldsDeleted.isEmpty && again.fieldsManual == ["Betrag", "Menge"])
    }

    @Test func anUntouchedTitleIsNotMarkedAsHandSet() async throws {
        let env = try ModelEnv()
        let model = env.model()
        await model.refresh()
        let item = try await env.store.create(ItemDraft(type: .text, title: "Auto", content: "x"), in: .unsorted)
        #expect(try await model.save(item).titleManual == false)
    }
}
