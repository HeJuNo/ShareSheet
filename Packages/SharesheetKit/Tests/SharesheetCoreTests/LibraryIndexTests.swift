import Foundation
import Testing
@testable import SharesheetCore

@Suite struct LibraryIndexTests {
    private func ids(_ items: [IndexedItem]) -> [String] { items.map(\.id.relativePath) }
    private func date(_ n: Int) -> Date { Date(timeIntervalSince1970: Double(n) * 1000) }

    @Test func searchMatchesTitleNoteAndArchiveText() throws {
        let index = try LibraryIndex(path: tempDB())
        try index.replaceAll(with: [
            .fixture(id: "Unsorted/A.md", title: "Router security"),
            .fixture(id: "Unsorted/B.md", title: "Other", note: "about routers"),
            .fixture(id: "Unsorted/C.md", title: "Third", archive: "_attachments/c.html"),
        ])
        try index.setArchiveText("deep router internals", forArchive: "_attachments/c.html")
        #expect(Set(ids(try index.search(.init(text: "router", scope: .all)))) == ["Unsorted/A.md", "Unsorted/B.md", "Unsorted/C.md"])
    }

    @Test func resultsNewestFirstAndTagFiltered() throws {
        let index = try LibraryIndex(path: tempDB())
        try index.replaceAll(with: [
            .fixture(id: "Unsorted/1.md", tags: ["x"], created: date(1)),
            .fixture(id: "Unsorted/2.md", tags: ["y"], created: date(2)),
            .fixture(id: "Unsorted/3.md", tags: ["X", "z"], created: date(3)),
        ])
        #expect(ids(try index.search(.init(scope: .all))) == ["Unsorted/3.md", "Unsorted/2.md", "Unsorted/1.md"])
        #expect(ids(try index.search(.init(scope: .all, tag: "x"))) == ["Unsorted/3.md", "Unsorted/1.md"])
        #expect(try index.search(.init(scope: .all)).first?.tags == ["X", "z"])
    }

    @Test func prefixSearchWorks() throws {
        let index = try LibraryIndex(path: tempDB())
        try index.replaceAll(with: [.fixture(title: "Router")])
        #expect(try index.search(.init(text: "rout", scope: .all)).count == 1)
        #expect(try index.search(.init(text: "  ", scope: .all)).count == 1)
    }

    @Test func countsRollUpNestedCollections() throws {
        let index = try LibraryIndex(path: tempDB())
        try index.replaceAll(with: [
            .fixture(id: "Billa/T.md", favorite: true),
            .fixture(id: "Billa/2026/U.md", type: .article, highlights: ["h"]),
            .fixture(id: "Unsorted/V.md"),
        ])
        let c = try index.counts()
        #expect(c.byCollection[CollectionPath(components: ["Billa"])] == 2)
        #expect(c.byCollection[CollectionPath(components: ["Billa", "2026"])] == 1)
        #expect(c.byCollection[.unsorted] == 1)
        #expect(c.all == 3 && c.unsorted == 1 && c.favorites == 1 && c.highlights == 1)
        #expect(c.byType == [.link: 2, .article: 1])
    }

    @Test func scopes() throws {
        let index = try LibraryIndex(path: tempDB())
        try index.replaceAll(with: [
            .fixture(id: "Billa/T.md", favorite: true),
            .fixture(id: "Billa/2026/U.md", type: .article, highlights: ["h"]),
            .fixture(id: "Unsorted/V.md"),
        ])
        #expect(Set(ids(try index.search(.init(scope: .collection(CollectionPath(components: ["Billa"])))))) == ["Billa/T.md", "Billa/2026/U.md"])
        #expect(ids(try index.search(.init(scope: .unsorted))) == ["Unsorted/V.md"])
        #expect(ids(try index.search(.init(scope: .favorites))) == ["Billa/T.md"])
        #expect(ids(try index.search(.init(scope: .highlights))) == ["Billa/2026/U.md"])
        #expect(ids(try index.search(.init(scope: .type(.article)))) == ["Billa/2026/U.md"])
    }

    @Test func domainStripsWww() throws {
        let index = try LibraryIndex(path: tempDB())
        try index.replaceAll(with: [.fixture(url: URL(string: "https://www.example.com/x")), .fixture(id: "Unsorted/N.md", type: .text, url: nil)])
        let found = try index.search(.init(scope: .all))
        #expect(found.first { $0.id.relativePath == "Unsorted/T.md" }?.domain == "example.com")
        #expect(found.first { $0.id.relativePath == "Unsorted/N.md" }?.domain == nil)
    }

    @Test func archiveTextSurvivesReplaceAll() throws {
        let index = try LibraryIndex(path: tempDB())
        let item = Item.fixture(archive: "_attachments/c.html")
        try index.replaceAll(with: [item])
        try index.setArchiveText("deep router internals", forArchive: "_attachments/c.html")
        try index.replaceAll(with: [item])
        #expect(try index.search(.init(text: "internals", scope: .all)).count == 1)
    }

    @Test func upsertAndRemove() throws {
        let index = try LibraryIndex(path: tempDB())
        var item = Item.fixture(title: "Alpha", tags: ["a"])
        try index.upsert(item)
        item.title = "Beta"; item.tags = ["b"]
        try index.upsert(item)
        #expect(try index.search(.init(text: "alpha", scope: .all)).isEmpty)
        #expect(try index.search(.init(text: "beta", scope: .all)).count == 1)
        #expect(try index.allTags() == ["b"])
        try index.remove(item.id)
        #expect(try index.search(.init(text: "beta", scope: .all)).isEmpty)
        #expect(try index.allTags().isEmpty)
    }

    @Test func tagsSortedByUse() throws {
        let index = try LibraryIndex(path: tempDB())
        try index.replaceAll(with: [.fixture(id: "Unsorted/1.md", tags: ["a", "b"]), .fixture(id: "Unsorted/2.md", tags: ["b"])])
        #expect(try index.allTags() == ["b", "a"])
    }

    @Test func readOnlyIndexCanSearch() throws {
        let path = tempDB()
        let writer = try LibraryIndex(path: path)
        try writer.replaceAll(with: [.fixture(tags: ["t"])])
        let reader = try LibraryIndex(path: path, readOnly: true)
        #expect(try reader.allTags() == ["t"])
        #expect(try reader.search(.init(text: "t", scope: .all)).count == 1)
    }

    @Test func readOnlyFailsWhenMissing() {
        #expect(throws: (any Error).self) { try LibraryIndex(path: tempDB(), readOnly: true) }
    }

    @Test func queryWithFTSSyntaxCharactersDoesNotThrow() throws {
        let index = try LibraryIndex(path: tempDB())
        try index.replaceAll(with: [.fixture(title: "a")])
        _ = try index.search(.init(text: "\"a OR (", scope: .all))
        _ = try index.search(.init(text: "\"", scope: .all))
        _ = try index.search(.init(text: "* - ^ :", scope: .all))
    }

    @Test func favicons() throws {
        let index = try LibraryIndex(path: tempDB())
        #expect(try index.favicon(host: "a.b") == nil)
        try index.setFavicon(Data([1, 2]), host: "a.b")
        try index.replaceAll(with: [])
        #expect(try index.favicon(host: "a.b") == Data([1, 2]))
    }
}
