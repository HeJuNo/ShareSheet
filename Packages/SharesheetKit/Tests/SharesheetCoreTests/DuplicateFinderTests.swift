import Foundation
import Testing
@testable import SharesheetCore

private func indexed(_ id: String, _ url: String, created: TimeInterval) -> IndexedItem {
    IndexedItem(
        id: ItemID(relativePath: id), type: .link, title: id,
        url: URL(string: url), created: Date(timeIntervalSince1970: created))
}

@Test func groupsItemsWithTheSameCanonicalURLOldestFirst() {
    let items = [
        indexed("Unsorted/New.md", "https://www.example.com/p/", created: 2),
        indexed("B/Old.md", "http://example.com/p", created: 1),
        indexed("Unsorted/Other.md", "https://example.com/other", created: 3),
    ]
    let groups = DuplicateFinder.groups(items)
    #expect(groups.count == 1)
    #expect(groups[0].key == "example.com/p")
    #expect(groups[0].items.map(\.id.relativePath) == ["B/Old.md", "Unsorted/New.md"])
    #expect(DuplicateFinder.extraCopyCount(items) == 1)
}

@Test func singleItemsAndNonWebLinksNeverFormAGroup() {
    let items = [
        indexed("Unsorted/A.md", "https://example.com/only", created: 1),
        IndexedItem(
            id: ItemID(relativePath: "Unsorted/File.md"), type: .text, title: "File",
            url: URL(string: "file:///tmp/x")!, created: Date(timeIntervalSince1970: 2)),
        IndexedItem(
            id: ItemID(relativePath: "Unsorted/NoURL.md"), type: .text, title: "No URL",
            created: Date(timeIntervalSince1970: 3)),
    ]
    #expect(DuplicateFinder.groups(items).isEmpty)
    #expect(DuplicateFinder.extraCopyCount(items) == 0)
}

private func sampleGroup() throws -> DuplicateGroup {
    let items = [
        indexed("Unsorted/Old.md", "https://example.com/p", created: 1),
        indexed("Unsorted/New.md", "http://www.example.com/p/", created: 2),
    ]
    return try #require(DuplicateFinder.groups(items).first)
}

@Test func keeperPrefersTheChosenItemWhenItIsInTheGroup() throws {
    let group = try sampleGroup()
    #expect(DuplicateFinder.keeper(in: group, chosen: group.items[1].id, currentID: group.items[1].id)
        == group.items[1].id)
}

@Test func keeperFollowsARedirectIntoTheGroup() throws {
    let group = try sampleGroup()
    let old = group.items[0].id
    let new = group.items[1].id
    #expect(DuplicateFinder.keeper(in: group, chosen: old, currentID: new) == new)
}

@Test func keeperFallsBackToTheOldestWhenTheChosenItemIsGone() throws {
    let group = try sampleGroup()
    let gone = ItemID(relativePath: "Unsorted/Gone.md")
    #expect(DuplicateFinder.keeper(in: group, chosen: gone, currentID: gone) == group.items[0].id)
    #expect(DuplicateFinder.keeper(in: group, chosen: nil, currentID: nil) == group.items[0].id)
}
