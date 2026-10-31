import Foundation
@testable import SharesheetCore

extension Item {
    static func fixture(
        id: String = "Unsorted/T.md",
        type: ItemType = .link,
        url: URL? = URL(string: "https://a.b/")!,
        file: String? = nil,
        title: String = "T",
        description: String? = nil,
        tags: [String] = [],
        favorite: Bool = false,
        created: Date = ISO8601DateFormatter().date(from: "2026-10-31T20:44:00Z")!,
        image: String? = nil,
        screenshot: String? = nil,
        archive: String? = nil,
        capture: CaptureState? = nil,
        content: String? = nil,
        note: String = "",
        highlights: [String] = [],
        extraFrontmatter: [String] = [],
        extraBody: String = ""
    ) -> Item {
        Item(
            id: ItemID(relativePath: id), type: type, url: url, file: file, title: title,
            description: description, tags: tags, favorite: favorite, created: created,
            image: image, screenshot: screenshot, archive: archive, capture: capture,
            note: note, content: content, highlights: highlights,
            extraFrontmatter: extraFrontmatter, extraBody: extraBody)
    }
}
