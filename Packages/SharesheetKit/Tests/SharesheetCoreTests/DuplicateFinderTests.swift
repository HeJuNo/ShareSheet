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
