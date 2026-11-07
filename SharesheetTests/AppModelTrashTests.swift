import Foundation
import SharesheetCore
import Testing

@testable import Sharesheet

@MainActor
struct AppModelTrashTests {
    private func defaults(autoEmpty: Bool? = nil, days: Int? = nil) -> UserDefaults {
        let suite = UserDefaults(suiteName: "trash-\(UUID().uuidString)")!
        if let autoEmpty { suite.set(autoEmpty, forKey: TrashSettings.autoEmptyKey) }
        if let days { suite.set(days, forKey: TrashSettings.daysKey) }
        return suite
    }

    private func stamp(_ env: ModelEnv, _ entry: TrashedItem, daysAgo: Double) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-daysAgo * 86_400)],
            ofItemAtPath: env.libraryRoot.appending(path: ".trash/\(entry.id)").path)
    }

    @Test func defaultsAreThirtyDaysAndOn() {
        let empty = defaults()
        #expect(TrashSettings.autoEmpties(empty) && TrashSettings.retentionDays(empty) == 30)
        #expect(TrashSettings.retentionDays(defaults(days: 5)) == 30, "a value that is not a choice falls back")
        #expect(TrashSettings.retentionDays(defaults(days: 7)) == 7)
    }

    @Test func deletingFillsTheTrashAndRestoringBringsTheItemBack() async throws {
        let env = try ModelEnv()
        let model = env.model()
        await model.refresh()
        let item = try await env.store.create(ItemDraft(type: .text, title: "Rechnung", content: "x"), in: .unsorted)
        try env.index.upsert(item)
        try await model.delete(item.id)
        #expect(!FileManager.default.fileExists(atPath: env.libraryRoot.appending(path: item.id.relativePath).path))
        #expect(model.items(LibraryQuery(scope: .all)).isEmpty)
        #expect(model.trashed.map(\.title) == ["Rechnung"])
        #expect(model.lastDeleted == model.trashed.first)
        #expect(model.counts.all == 0)

        try await model.restore(try #require(model.trashed.first))
        #expect(model.trashed.isEmpty && model.lastDeleted == nil)
        #expect(model.counts.all == 1)
    }

    @Test func onlyItemsOlderThanTheChosenTimeAreDeletedForGood() async throws {
        let env = try ModelEnv()
        let model = env.model()
        await model.refresh()
        for title in ["Alt", "Neu"] {
            let item = try await env.store.create(ItemDraft(type: .text, title: title, content: "x"), in: .unsorted)
            try env.index.upsert(item)
            try await model.delete(item.id)
        }
        for entry in model.trashed { try stamp(env, entry, daysAgo: entry.title == "Alt" ? 31 : 29) }
        let removed = await model.purgeExpired(defaults: defaults(autoEmpty: true, days: 30))
        #expect(removed == 1)
        #expect(model.trashed.map(\.title) == ["Neu"])
    }

    @Test func switchedOffNothingIsDeletedAutomatically() async throws {
        let env = try ModelEnv()
        let model = env.model()
        await model.refresh()
        let item = try await env.store.create(ItemDraft(type: .text, title: "Alt", content: "x"), in: .unsorted)
        try env.index.upsert(item)
        try await model.delete(item.id)
        try stamp(env, try #require(model.trashed.first), daysAgo: 400)
        #expect(await model.purgeExpired(defaults: defaults(autoEmpty: false)) == 0)
        #expect(model.trashed.count == 1)
    }

    @Test func aShorterTimeDeletesMore() async throws {
        let env = try ModelEnv()
        let model = env.model()
        await model.refresh()
        let item = try await env.store.create(ItemDraft(type: .text, title: "A", content: "x"), in: .unsorted)
        try env.index.upsert(item)
        try await model.delete(item.id)
        try stamp(env, try #require(model.trashed.first), daysAgo: 10)
        #expect(await model.purgeExpired(defaults: defaults(autoEmpty: true, days: 30)) == 0)
        #expect(await model.purgeExpired(defaults: defaults(autoEmpty: true, days: 7)) == 1)
    }

    @Test func emptyingAndPurgingOneEntry() async throws {
        let env = try ModelEnv()
        let model = env.model()
        await model.refresh()
        for title in ["A", "B"] {
            let item = try await env.store.create(ItemDraft(type: .text, title: title, content: "x"), in: .unsorted)
            try env.index.upsert(item)
            try await model.delete(item.id)
        }
        try await model.purge(try #require(model.trashed.first))
        #expect(model.trashed.count == 1)
        try await model.emptyTrash()
        #expect(model.trashed.isEmpty)
    }
}
