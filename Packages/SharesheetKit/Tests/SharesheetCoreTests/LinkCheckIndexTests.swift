import Foundation
import GRDB
import Testing
@testable import SharesheetCore

@Suite struct LinkCheckIndexTests {
    private func date(_ n: Int) -> Date { Date(timeIntervalSince1970: Double(n) * 1000) }
    private func url(_ path: String) -> URL { URL(string: "https://a.test/\(path)")! }

    private func indexWith(_ items: [Item]) throws -> LibraryIndex {
        let index = try LibraryIndex(path: tempDB())
        try index.replaceAll(with: items)
        return index
    }

    @Test func brokenChecksCountAndListTheirItems() throws {
        let broken = url("broken")
        let index = try indexWith([
            .fixture(id: "Unsorted/A.md", url: broken, title: "A"),
            .fixture(id: "Unsorted/B.md", url: broken, title: "B"),
            .fixture(id: "Unsorted/C.md", url: url("ok"), title: "C"),
        ])
        try index.recordLinkCheck(.init(status: .broken, httpStatus: 404), for: broken, checked: date(2))

        #expect(try index.counts().brokenLinks == 2)
        #expect(try index.brokenLinks().map(\.item.title).sorted() == ["A", "B"])
        let check = try #require(try index.linkCheck(for: broken))
        #expect(check.status == .broken)
        #expect(check.httpStatus == 404)
        #expect(check.checked == date(2))
    }

    @Test func unknownNeverOverwritesAKnownStatusButUpdatesChecked() throws {
        let target = url("broken")
        let index = try indexWith([.fixture(id: "Unsorted/A.md", url: target)])
        try index.recordLinkCheck(.init(status: .broken, httpStatus: 410), for: target, checked: date(1))
        try index.recordLinkCheck(.init(status: .unknown), for: target, checked: date(2))

        let check = try #require(try index.linkCheck(for: target))
        #expect(check.status == .broken)
        #expect(check.httpStatus == 410)
        #expect(check.checked == date(2))
    }

    @Test func unknownWithoutARowIsStoredButNotListed() throws {
        let target = url("unknown")
        let index = try indexWith([.fixture(id: "Unsorted/A.md", url: target, title: "A")])
        try index.recordLinkCheck(.init(status: .unknown), for: target, checked: date(1))

        #expect(try index.linkCheck(for: target)?.status == .unknown)
        #expect(try index.counts().brokenLinks == 0)
        #expect(try index.brokenLinks().isEmpty)
    }

    @Test func linksToCheckReturnsOnlyStaleWebURLsWithoutDuplicates() throws {
        let never = url("never")
        let fresh = url("fresh")
        let stale = url("stale")
        let file = URL(string: "file:///tmp/x")!
        let index = try indexWith([
            .fixture(id: "Unsorted/A.md", url: never),
            .fixture(id: "Unsorted/B.md", url: fresh),
            .fixture(id: "Unsorted/C.md", url: stale),
            .fixture(id: "Unsorted/D.md", url: file),
            .fixture(id: "Unsorted/E.md", url: never),
        ])
        try index.recordLinkCheck(.init(status: .ok, httpStatus: 200), for: fresh, checked: date(200))
        try index.recordLinkCheck(.init(status: .ok, httpStatus: 200), for: stale, checked: date(50))

        let due = try index.linksToCheck(limit: 10, checkedBefore: date(100))
        #expect(due == [never, stale])
        #expect(try index.linksToCheck(limit: 1, checkedBefore: date(100)).count == 1)
    }
}
