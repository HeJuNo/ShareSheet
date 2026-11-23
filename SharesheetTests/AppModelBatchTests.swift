import Foundation
import Testing
@testable import Sharesheet
import SharesheetCore

@MainActor
struct AppModelBatchTests {
    private func draft(_ title: String, tags: [String] = []) -> ItemDraft {
        ItemDraft(type: .text, title: title, tags: tags)
    }

    @Test func batchMoveReportsOnlyTheMissingItem() async throws {
        let env = try ModelEnv()
        let a = try await env.store.create(draft("A"), in: .unsorted)
        let b = try await env.store.create(draft("B"), in: .unsorted)
        let model = env.model()
        await model.refresh()
        let missing = ItemID(relativePath: "Unsorted/Missing.md")
        let target = CollectionPath(components: ["Billa"])

        let failed = await model.move([a.id, missing, b.id], to: target)

        #expect(failed == [missing])
        let all = try await env.store.listItems()
        #expect(all.filter { $0.id.collection == target }.map(\.title).sorted() == ["A", "B"])
    }

    @Test func batchDeleteTrashesTheOthersAndReportsTheMissing() async throws {
        let env = try ModelEnv()
        let a = try await env.store.create(draft("A"), in: .unsorted)
        let b = try await env.store.create(draft("B"), in: .unsorted)
        let model = env.model()
        await model.refresh()
        let missing = ItemID(relativePath: "Unsorted/Missing.md")

        let failed = await model.delete([a.id, missing, b.id])

        #expect(failed == [missing])
        #expect(try await env.store.listItems().isEmpty)
        #expect(model.trashed.count == 2)
        #expect(model.lastDeleted == nil)
        #expect(model.items(LibraryQuery(scope: .all)).isEmpty)
    }

    @Test func batchTagResolvesToTheExistingSpelling() async throws {
        let env = try ModelEnv()
        let a = try await env.store.create(draft("A", tags: ["Rechnung"]), in: .unsorted)
        let b = try await env.store.create(draft("B"), in: .unsorted)
        let model = env.model()
        await model.refresh()

        let failed = await model.addTag("Rechnungen", to: [a.id, b.id])

        #expect(failed.isEmpty)
        #expect(try await env.store.item(a.id).tags == ["Rechnung"])
        #expect(try await env.store.item(b.id).tags == ["Rechnung"])
    }

    @Test func anUnusableBatchTagChangesNothing() async throws {
        let env = try ModelEnv()
        let a = try await env.store.create(draft("A"), in: .unsorted)
        let model = env.model()
        await model.refresh()

        let failed = await model.addTag("one two three four", to: [a.id])

        #expect(failed == [a.id])
        #expect(try await env.store.item(a.id).tags.isEmpty)
    }

    @Test func duplicateCountAndGroupsFollowTheLibrary() async throws {
        let env = try ModelEnv()
        _ = try await env.store.create(ItemDraft(
            type: .link, url: URL(string: "https://www.example.com/p/")!, title: "A",
            created: Date(timeIntervalSince1970: 1)), in: .unsorted)
        _ = try await env.store.create(ItemDraft(
            type: .link, url: URL(string: "http://example.com/p")!, title: "B",
            created: Date(timeIntervalSince1970: 2)), in: .unsorted)
        _ = try await env.store.create(ItemDraft(
            type: .link, url: URL(string: "https://example.com/other")!, title: "C",
            created: Date(timeIntervalSince1970: 3)), in: .unsorted)
        let model = env.model()
        await model.refresh()

        #expect(model.duplicateCopyCount == 1)
        #expect(model.duplicateGroups().count == 1)
        #expect(model.duplicateGroups().first?.items.map(\.title) == ["A", "B"])
    }
}
