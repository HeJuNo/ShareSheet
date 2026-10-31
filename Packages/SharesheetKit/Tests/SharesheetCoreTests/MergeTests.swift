import Testing
import Foundation
@testable import SharesheetCore

@Test func applyingMergesOnlyChangedFields() {
    let item = Item.fixture(title: "Edited in Obsidian", tags: ["a", "b"], note: "old", highlights: ["h1"])
    let out = item.applying(SheetEdits(note: "new", addedTags: ["c"], removedTags: ["a"]), highlight: "h2")
    #expect(out.title == "Edited in Obsidian" && out.note == "new")
    #expect(out.tags == ["b", "c"] && out.highlights == ["h1", "h2"])
    #expect(item.applying(SheetEdits(), highlight: "h1").highlights == ["h1"])
}

@Test func applyingSetsTypeTitleFavoriteAndKeepsTagOrder() {
    let item = Item.fixture(type: .link, title: "Old", tags: ["x", "y"], favorite: false)
    let out = item.applying(
        SheetEdits(type: .article, title: "New", favorite: true, addedTags: ["y", "z"]), highlight: nil)
    #expect(out.type == .article && out.title == "New" && out.favorite)
    #expect(out.tags == ["x", "y", "z"])
}
