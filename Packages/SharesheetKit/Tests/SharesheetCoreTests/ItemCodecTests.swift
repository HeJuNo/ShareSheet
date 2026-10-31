import Foundation
import Testing
@testable import SharesheetCore

@Test func encodesLinkExactly() {
    let item = Item.fixture(type: .link, url: URL(string: "https://pamba.app/")!,
        title: "Pamba | The AI creator engine behind 500M+ views", tags: ["ai", "marketing"],
        created: ISO8601DateFormatter().date(from: "2026-10-31T20:44:00Z")!,
        capture: .pending, note: "My note", highlights: ["quoted passage"])
    #expect(ItemCodec.encode(item) == """
    ---
    type: link
    url: "https://pamba.app/"
    title: "Pamba | The AI creator engine behind 500M+ views"
    tags: ["ai", "marketing"]
    favorite: false
    created: 2026-10-31T20:44:00Z
    capture: pending
    ---

    My note

    ## Highlights

    > quoted passage

    """)
}
@Test func roundTripsSpecialCharacters() throws {
    let item = Item.fixture(title: "Say \"hi\": #1 \\ 你无法逆向你的项目！\nline2", description: "a: b # c")
    let decoded = try ItemCodec.decode(ItemCodec.encode(item), id: item.id)
    #expect(decoded == item)
}
@Test func preservesUnknownKeysAndExtraBody() throws {
    let text = "---\ntype: link\nurl: \"https://a.b/\"\ntitle: \"T\"\ntags: []\nfavorite: false\ncreated: 2026-10-31T20:44:00Z\nobsidian-cssclass: wide\n---\n\nnote\n\n## Highlights\n\n> h1\n\nfooter text\n"
    let item = try ItemCodec.decode(text, id: ItemID(relativePath: "Unsorted/T.md"))
    #expect(item.extraFrontmatter == ["obsidian-cssclass: wide"])
    #expect(item.highlights == ["h1"] && item.extraBody == "footer text\n")
    #expect(ItemCodec.encode(item) == text)
}
@Test func textItemPutsContentFirstThenNote() throws {
    let item = Item.fixture(type: .text, url: nil, content: "Shared paragraph", note: "why")
    #expect(ItemCodec.encode(item).contains("---\n\nShared paragraph\n\n## Note\n\nwhy\n"))
    #expect(try ItemCodec.decode(ItemCodec.encode(item), id: item.id) == item)
}
@Test func multilineHighlightRoundTrips() throws {
    let item = Item.fixture(highlights: ["first line\nsecond line"])
    #expect(try ItemCodec.decode(ItemCodec.encode(item), id: item.id).highlights == ["first line\nsecond line"])
}
