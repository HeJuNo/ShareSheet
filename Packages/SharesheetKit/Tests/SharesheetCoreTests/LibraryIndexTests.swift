import Foundation
import GRDB
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
        #expect(ids(try index.search(.init(scope: .all, tags: ["x"]))) == ["Unsorted/3.md", "Unsorted/1.md"])
        #expect(try index.search(.init(scope: .all)).first?.tags == ["X", "z"])
    }

    @Test func severalTagsNarrowAndExcludedTagsRemove() throws {
        let index = try LibraryIndex(path: tempDB())
        try index.replaceAll(with: [
            .fixture(id: "Unsorted/1.md", tags: ["Rechnung", "Strom"], created: date(1)),
            .fixture(id: "Unsorted/2.md", tags: ["rechnung", "Gas", "Strom"], created: date(2)),
            .fixture(id: "Unsorted/3.md", tags: ["Rechnung"], created: date(3)),
            .fixture(id: "Unsorted/4.md", tags: [], created: date(4)),
        ])
        #expect(ids(try index.search(.init(scope: .all, tags: ["Rechnung", "strom"]))) == ["Unsorted/2.md", "Unsorted/1.md"])
        #expect(ids(try index.search(.init(scope: .all, tags: ["Rechnung"], excludedTags: ["Gas"]))) == ["Unsorted/3.md", "Unsorted/1.md"])
        #expect(ids(try index.search(.init(scope: .all, excludedTags: ["Rechnung"]))) == ["Unsorted/4.md"])
        #expect(try index.search(.init(scope: .all, tags: ["Rechnung"], excludedTags: ["Rechnung"])).isEmpty)
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

    @Test func itemIDForURLIgnoresTrackingParameters() throws {
        let path = tempDB()
        let writer = try LibraryIndex(path: path)
        try writer.replaceAll(with: [
            .fixture(id: "Unsorted/A.md", url: URL(string: "https://www.example.com/a?utm_source=feed&id=1")!),
            .fixture(id: "Unsorted/B.md", url: URL(string: "https://example.com/b")!),
            .fixture(id: "Unsorted/C.md", url: nil),
        ])
        let reader = try LibraryIndex(path: path, readOnly: true)
        #expect(try reader.itemID(forURL: URL(string: "https://www.example.com/a?id=1&fbclid=z")!) == ItemID(relativePath: "Unsorted/A.md"))
        #expect(try reader.itemID(forURL: URL(string: "https://example.com/b?si=q")!) == ItemID(relativePath: "Unsorted/B.md"))
        #expect(try reader.itemID(forURL: URL(string: "https://example.com/missing")!) == nil)
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

    // MARK: Analysis

    @Test func documentTextIsSearchable() throws {
        let index = try LibraryIndex(path: tempDB())
        let item = Item.fixture(id: "Unsorted/A.md", type: .document, url: nil, file: "_attachments/a.pdf", title: "Scan")
        try index.replaceAll(with: [item])
        try index.setAnalysis(source: "_attachments/a.pdf", text: "Beitragsvorschreibung Oktober", keywords: [], suggestedTag: nil)
        #expect(try index.search(.init(text: "vorschreibung", scope: .all)).isEmpty)
        #expect(ids(try index.search(.init(text: "beitragsvor", scope: .all))) == ["Unsorted/A.md"])
        try index.replaceAll(with: [item])
        #expect(ids(try index.search(.init(text: "beitragsvor", scope: .all))) == ["Unsorted/A.md"])
    }

    @Test func keywordsOutrankBodyText() throws {
        let index = try LibraryIndex(path: tempDB())
        try index.replaceAll(with: [
            .fixture(id: "Unsorted/Old.md", type: .document, url: nil, file: "_attachments/old.pdf", title: "Old", created: date(1)),
            .fixture(id: "Unsorted/New.md", type: .document, url: nil, file: "_attachments/new.pdf", title: "New", created: date(2)),
        ])
        let filler = Array(repeating: "lorem ipsum dolor sit amet", count: 20).joined(separator: " ")
        try index.setAnalysis(source: "_attachments/new.pdf", text: filler + " steuer", keywords: [], suggestedTag: nil)
        try index.setAnalysis(
            source: "_attachments/old.pdf", text: filler, keywords: [Keyword(term: "steuer", score: 1)], suggestedTag: nil)
        #expect(ids(try index.search(.init(text: "steuer", scope: .all))) == ["Unsorted/Old.md", "Unsorted/New.md"])
    }

    @Test func candidatesAreItemsWithoutAnalysis() throws {
        let index = try LibraryIndex(path: tempDB())
        try index.replaceAll(with: [
            .fixture(id: "Unsorted/F.md", type: .document, url: nil, file: "_attachments/f.pdf", title: "F"),
            .fixture(id: "Unsorted/W.md", title: "W", archive: "_attachments/w.html"),
            .fixture(id: "Unsorted/N.md", title: "N"),
        ])
        let all = try index.analysisCandidates()
        #expect(Set(all.map(\.id.relativePath)) == ["Unsorted/F.md", "Unsorted/W.md"])
        #expect(all.first { $0.id.relativePath == "Unsorted/F.md" }?.isFile == true)
        #expect(all.first { $0.id.relativePath == "Unsorted/W.md" }?.source == "_attachments/w.html")
        try index.setAnalysis(source: "_attachments/f.pdf", text: "x", keywords: [], suggestedTag: nil)
        try index.setAnalysis(source: "_attachments/w.html", text: nil, keywords: [], suggestedTag: nil)
        #expect(try index.analysisCandidates().isEmpty)
        try index.clearAnalysis()
        #expect(try index.analysisCandidates().count == 2)
    }

    @Test func replaceAllPrunesOrphanAnalysisButKeepsSurvivors() throws {
        let index = try LibraryIndex(path: tempDB())
        let keep = Item.fixture(id: "Unsorted/K.md", type: .document, url: nil, file: "_attachments/k.pdf", title: "K")
        let gone = Item.fixture(id: "Unsorted/G.md", type: .document, url: nil, file: "_attachments/g.pdf", title: "G")
        let page = Item.fixture(id: "Unsorted/P.md", title: "P", archive: "_attachments/p.html")
        try index.replaceAll(with: [keep, gone, page])
        try index.setAnalysis(source: "_attachments/k.pdf", text: "kept", keywords: [], suggestedTag: nil)
        try index.setAnalysis(source: "_attachments/g.pdf", text: "orphaned", keywords: [], suggestedTag: nil)
        try index.setAnalysis(source: "_attachments/p.html", text: nil, keywords: [], suggestedTag: nil)
        try index.replaceAll(with: [keep, page])
        #expect(try index.analysisCandidates().isEmpty)
        try index.replaceAll(with: [keep, gone, page])
        #expect(try index.analysisCandidates().map(\.source) == ["_attachments/g.pdf"])
        #expect(ids(try index.search(.init(text: "kept", scope: .all))) == ["Unsorted/K.md"])
    }

    @Test func removeAnalysisForSourceKeepsRowsStillInUse() throws {
        let index = try LibraryIndex(path: tempDB())
        let item = Item.fixture(id: "Unsorted/F.md", type: .document, url: nil, file: "_attachments/f.pdf", title: "F")
        try index.replaceAll(with: [item])
        try index.setAnalysis(source: "_attachments/f.pdf", text: "x", keywords: [], suggestedTag: nil)
        try index.removeAnalysis(forSource: "_attachments/f.pdf")
        #expect(try index.analysisCandidates().isEmpty)  // still referenced: kept
        try index.remove(item.id)
        try index.upsert(.fixture(id: "Unsorted/F2.md", type: .document, url: nil, file: "_attachments/f.pdf", title: "F2"))
        try index.removeAnalysis(forSource: "_attachments/f.pdf")
        #expect(try index.analysisCandidates().isEmpty)  // referenced by the new item: kept
        try index.remove(ItemID(relativePath: "Unsorted/F2.md"))
        try index.removeAnalysis(forSource: "_attachments/f.pdf")
        try index.upsert(.fixture(id: "Unsorted/F3.md", type: .document, url: nil, file: "_attachments/f.pdf", title: "F3"))
        #expect(try index.analysisCandidates().count == 1)
    }

    @Test func upsertAndRemoveKeepAnalysis() throws {
        let index = try LibraryIndex(path: tempDB())
        let item = Item.fixture(id: "Unsorted/F.md", type: .document, url: nil, file: "_attachments/f.pdf", title: "F")
        try index.replaceAll(with: [item])
        try index.setAnalysis(source: "_attachments/f.pdf", text: "x", keywords: [], suggestedTag: nil)
        try index.upsert(item)
        #expect(try index.analysisCandidates().isEmpty)
        try index.remove(item.id)
        try index.upsert(item)
        #expect(try index.analysisCandidates().isEmpty)
    }

    @Test func suggestedTagCanBeSetAndCleared() throws {
        let index = try LibraryIndex(path: tempDB())
        let id = ItemID(relativePath: "Unsorted/F.md")
        try index.replaceAll(with: [.fixture(id: "Unsorted/F.md", type: .document, url: nil, file: "_attachments/f.pdf", title: "F")])
        try index.setAnalysis(source: "_attachments/f.pdf", text: "x", keywords: [], suggestedTag: nil)
        #expect(try index.analysis(forItem: id)?.suggestedTag == nil)
        try index.setSuggestedTag("Steuer", forSource: "_attachments/f.pdf")
        #expect(try index.analysis(forItem: id)?.suggestedTag == "Steuer")
        try index.setSuggestedTag(nil, forSource: "_attachments/f.pdf")
        #expect(try index.analysis(forItem: id)?.suggestedTag == nil)
        #expect(try index.analysis(forItem: ItemID(relativePath: "Unsorted/none.md")) == nil)
    }

    @Test func suggestedTagCanBeClearedByItem() throws {
        let index = try LibraryIndex(path: tempDB())
        let id = ItemID(relativePath: "Unsorted/F.md")
        try index.replaceAll(with: [.fixture(id: "Unsorted/F.md", type: .document, url: nil, file: "_attachments/f.pdf", title: "F")])
        try index.setAnalysis(source: "_attachments/f.pdf", text: "x", keywords: [], suggestedTag: "Steuer")
        try index.setSuggestedTag(nil, forItem: id)
        #expect(try index.analysis(forItem: id)?.suggestedTag == nil)
        #expect(try index.analysis(forItem: id) != nil)
    }

    @Test func analysisForItemReturnsKeywordsInScoreOrder() throws {
        let index = try LibraryIndex(path: tempDB())
        let id = ItemID(relativePath: "Unsorted/F.md")
        try index.replaceAll(with: [.fixture(id: "Unsorted/F.md", type: .document, url: nil, file: "_attachments/f.pdf", title: "F")])
        try index.setAnalysis(
            source: "_attachments/f.pdf", text: "t",
            keywords: [Keyword(term: "b", score: 1), Keyword(term: "a", score: 3), Keyword(term: "c", score: 2)],
            suggestedTag: "T")
        #expect(try index.analysis(forItem: id)?.keywords.map(\.term) == ["a", "c", "b"])
        #expect(try index.analysisText(forItem: id) == "t")
    }

    @Test func analysisTextForWebItemIsArchiveText() throws {
        let index = try LibraryIndex(path: tempDB())
        let id = ItemID(relativePath: "Unsorted/W.md")
        try index.replaceAll(with: [.fixture(id: "Unsorted/W.md", title: "W", archive: "_attachments/w.html")])
        #expect(try index.analysisText(forItem: id) == nil)
        try index.setArchiveText("page body", forArchive: "_attachments/w.html")
        #expect(try index.analysisText(forItem: id) == "page body")
    }

    @Test func documentFrequenciesCountDocumentsContainingTerms() throws {
        let index = try LibraryIndex(path: tempDB())
        try index.replaceAll(with: [
            .fixture(id: "Unsorted/1.md", type: .document, url: nil, file: "_attachments/1.pdf", title: "1"),
            .fixture(id: "Unsorted/2.md", type: .document, url: nil, file: "_attachments/2.pdf", title: "2"),
            .fixture(id: "Unsorted/3.md", title: "3", archive: "_attachments/3.html"),
            .fixture(id: "Unsorted/4.md", title: "no text"),
        ])
        try index.setAnalysis(source: "_attachments/1.pdf", text: "Rechnung Strom", keywords: [], suggestedTag: nil)
        try index.setAnalysis(source: "_attachments/2.pdf", text: "Vertrag", keywords: [], suggestedTag: nil)
        try index.setArchiveText("Eine Rechnung online", forArchive: "_attachments/3.html")
        let result = try index.documentFrequencies(of: ["rechnung", "vertrag", "fehlt"])
        #expect(result.documents == 3)
        #expect(result.frequencies["rechnung"] == 2)
        #expect(result.frequencies["vertrag"] == 1)
        #expect((result.frequencies["fehlt"] ?? 0) == 0)
    }

    @Test func taggedExamplesPairEachTagWithDocumentTextNewestFirst() throws {
        let index = try LibraryIndex(path: tempDB())
        try index.replaceAll(with: [
            .fixture(id: "Unsorted/1.md", type: .document, url: nil, file: "_attachments/1.pdf", title: "1", tags: ["Rechnung", "Strom"], created: date(1)),
            .fixture(id: "Unsorted/2.md", type: .document, url: nil, file: "_attachments/2.pdf", title: "2", tags: ["Vertrag"], created: date(2)),
            .fixture(id: "Unsorted/3.md", type: .document, url: nil, file: "_attachments/3.pdf", title: "3", tags: [], created: date(3)),
            .fixture(id: "Unsorted/4.md", title: "page", tags: ["Web"], created: date(4), archive: "_attachments/4.html"),
        ])
        try index.setAnalysis(source: "_attachments/1.pdf", text: "Rechnung Strom", keywords: [], suggestedTag: nil)
        try index.setAnalysis(source: "_attachments/2.pdf", text: "Vertrag", keywords: [], suggestedTag: nil)
        try index.setAnalysis(source: "_attachments/3.pdf", text: "untagged", keywords: [], suggestedTag: nil)
        try index.setAnalysis(source: "_attachments/4.html", text: nil, keywords: [], suggestedTag: nil)
        let examples = try index.taggedExamples(limit: 10)
        #expect(examples.map(\.tag) == ["Vertrag", "Rechnung", "Strom"])
        #expect(examples.map(\.text) == ["Vertrag", "Rechnung Strom", "Rechnung Strom"])
        #expect(try index.taggedExamples(limit: 1).count == 1)
    }

    @Test func searchWithoutTextStaysNewestFirst() throws {
        let index = try LibraryIndex(path: tempDB())
        try index.replaceAll(with: [
            .fixture(id: "Unsorted/1.md", type: .document, url: nil, file: "_attachments/1.pdf", title: "x", created: date(1)),
            .fixture(id: "Unsorted/2.md", type: .document, url: nil, file: "_attachments/2.pdf", title: "x", created: date(2)),
        ])
        try index.setAnalysis(source: "_attachments/1.pdf", text: "x", keywords: [Keyword(term: "x", score: 9)], suggestedTag: nil)
        #expect(ids(try index.search(.init(scope: .all))) == ["Unsorted/2.md", "Unsorted/1.md"])
    }

    @Test func migrationV2RepopulatesExistingIndex() throws {
        let path = tempDB()
        // A database as an app before this version left it: schema v1 only, filled with a plain FTS insert.
        do {
            let pool = try DatabasePool(path: path.path)
            try LibraryIndex.migrator.migrate(pool, upTo: "v1")
            try pool.write { db in
                let rows: [(String, String, String?, String?)] = [
                    ("Unsorted/F.md", "Scan", "_attachments/f.pdf", nil),
                    ("Unsorted/W.md", "Web page", nil, "_attachments/w.html"),
                    ("Unsorted/P.md", "Plain router note", nil, nil),
                ]
                for (id, title, file, archive) in rows {
                    try db.execute(sql: """
                        INSERT INTO items(id, type, title, file, created, favorite, has_highlights, collection, note,
                                          highlights, archive)
                        VALUES (?, 'link', ?, ?, 0, 0, 0, 'Unsorted', '', '', ?)
                        """, arguments: [id, title, file, archive])
                    try db.execute(sql: """
                        INSERT INTO items_fts(rowid, title, note, description, url, highlights, archive_text)
                        VALUES (?, ?, '', '', '', '', ?)
                        """, arguments: [db.lastInsertedRowID, title, archive == nil ? "" : "deep internals"])
                }
                try db.execute(sql: "INSERT INTO archive_text(archive, text) VALUES ('_attachments/w.html', 'deep internals')")
            }
        }
        let index = try LibraryIndex(path: path)
        #expect(ids(try index.search(.init(text: "router", scope: .all))) == ["Unsorted/P.md"])
        #expect(ids(try index.search(.init(text: "inter", scope: .all))) == ["Unsorted/W.md"])
        #expect(ids(try index.search(.init(text: "sca", scope: .all))) == ["Unsorted/F.md"])
        #expect(try index.search(.init(scope: .all)).count == 3)
        try index.setAnalysis(source: "_attachments/f.pdf", text: "Beitragsvorschreibung", keywords: [], suggestedTag: nil)
        #expect(ids(try index.search(.init(text: "beitragsvor", scope: .all))) == ["Unsorted/F.md"])
        #expect(try index.analysisCandidates().map(\.source) == ["_attachments/w.html"])
    }

    @Test func favicons() throws {
        let index = try LibraryIndex(path: tempDB())
        #expect(try index.favicon(host: "a.b") == nil)
        try index.setFavicon(Data([1, 2]), host: "a.b")
        try index.replaceAll(with: [])
        #expect(try index.favicon(host: "a.b") == Data([1, 2]))
    }

    @Test func collectionScopeHandlesUnicodeNamesAndSiblingPrefixes() throws {
        let index = try LibraryIndex(path: tempDB())
        let nfd = "Cafe\u{301}", emoji = "\u{1F600}\u{1F44D}"
        try index.replaceAll(with: [
            .fixture(id: "\(nfd)/A.md"), .fixture(id: "\(nfd)/Sub/B.md"),
            .fixture(id: "\(emoji)/C.md"), .fixture(id: "\(emoji)/Sub/D.md"),
            .fixture(id: "Billa/E.md"), .fixture(id: "Billa2/F.md"), .fixture(id: "Bill_/G.md"),
        ])
        #expect(Set(ids(try index.search(.init(scope: .collection(CollectionPath(components: [nfd])))))) == ["\(nfd)/A.md", "\(nfd)/Sub/B.md"])
        #expect(Set(ids(try index.search(.init(scope: .collection(CollectionPath(components: [emoji])))))) == ["\(emoji)/C.md", "\(emoji)/Sub/D.md"])
        #expect(ids(try index.search(.init(scope: .collection(CollectionPath(components: ["Billa"]))))) == ["Billa/E.md"])
    }

    @Test func publicInitializersExist() {
        let counts = LibraryCounts()
        #expect(counts.all == 0 && counts.byType.isEmpty)
        let item = IndexedItem(id: ItemID(relativePath: "A/B.md"), type: .link, title: "t", created: .distantPast)
        #expect(item.tags.isEmpty && !item.favorite && item.url == nil)
    }
}

@Test func anObservingIndexRefusesWritesWhileSuspended() throws {
    let index = try LibraryIndex(path: tempDB(), observesSuspension: true)
    let bystander = try LibraryIndex(path: tempDB())
    LibraryIndex.suspend()
    #expect(throws: (any Error).self) { try index.upsert(.fixture()) }
    try bystander.upsert(.fixture())
    LibraryIndex.resume()
    try index.upsert(.fixture())
    #expect(try index.search(LibraryQuery(scope: .all)).count == 1)
}
