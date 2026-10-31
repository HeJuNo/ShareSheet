import Foundation

public struct CollectionPath: Hashable, Comparable, Codable, Sendable {
    public var components: [String]

    public init(components: [String]) {
        self.components = components
    }

    public static let root = CollectionPath(components: [])
    public static let unsorted = CollectionPath(components: ["Unsorted"])

    public var name: String { components.last ?? "" }

    public var parent: CollectionPath? {
        components.isEmpty ? nil : CollectionPath(components: Array(components.dropLast()))
    }

    public var relativePath: String { components.joined(separator: "/") }

    public static func < (lhs: CollectionPath, rhs: CollectionPath) -> Bool {
        lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
    }
}

public struct ItemID: Hashable, Codable, Sendable {
    public var relativePath: String

    public init(relativePath: String) {
        self.relativePath = relativePath
    }

    public var collection: CollectionPath {
        CollectionPath(components: relativePath.split(separator: "/").dropLast().map(String.init))
    }
}

public struct Item: Equatable, Sendable {
    public var id: ItemID
    public var type: ItemType
    public var url: URL?
    public var file: String?
    public var title: String
    public var description: String?
    public var tags: [String]
    public var favorite: Bool
    public var created: Date
    public var image: String?
    public var screenshot: String?
    public var archive: String?
    public var capture: CaptureState?
    public var note: String
    /// Shared text, `.text` items only.
    public var content: String?
    public var highlights: [String]
    /// Unknown raw frontmatter lines, verbatim, in order.
    public var extraFrontmatter: [String]
    /// Body text after the highlight quotes, verbatim.
    public var extraBody: String

    public init(
        id: ItemID, type: ItemType, url: URL? = nil, file: String? = nil, title: String,
        description: String? = nil, tags: [String] = [], favorite: Bool = false, created: Date,
        image: String? = nil, screenshot: String? = nil, archive: String? = nil,
        capture: CaptureState? = nil, note: String = "", content: String? = nil,
        highlights: [String] = [], extraFrontmatter: [String] = [], extraBody: String = ""
    ) {
        self.id = id
        self.type = type
        self.url = url
        self.file = file
        self.title = title
        self.description = description
        self.tags = tags
        self.favorite = favorite
        self.created = created
        self.image = image
        self.screenshot = screenshot
        self.archive = archive
        self.capture = capture
        self.note = note
        self.content = content
        self.highlights = highlights
        self.extraFrontmatter = extraFrontmatter
        self.extraBody = extraBody
    }
}

/// Everything needed to create a new item; the store assigns the id, file names and attachments.
public struct ItemDraft: Sendable {
    public var type: ItemType
    public var url: URL?
    public var title: String
    public var description: String?
    public var tags: [String]
    public var favorite: Bool
    public var note: String
    public var content: String?
    public var highlights: [String]
    public var created: Date
    /// Local file to copy into `_attachments`.
    public var fileSource: URL?
    public var previewImageSource: URL?
    public var capture: CaptureState?

    public init(
        type: ItemType, url: URL? = nil, title: String, description: String? = nil,
        tags: [String] = [], favorite: Bool = false, note: String = "", content: String? = nil,
        highlights: [String] = [], created: Date = Date(), fileSource: URL? = nil,
        previewImageSource: URL? = nil, capture: CaptureState? = nil
    ) {
        self.capture = capture
        self.type = type
        self.url = url
        self.title = title
        self.description = description
        self.tags = tags
        self.favorite = favorite
        self.note = note
        self.content = content
        self.highlights = highlights
        self.created = created
        self.fileSource = fileSource
        self.previewImageSource = previewImageSource
    }
}

extension Item {
    /// Merges the fields the user changed in the share sheet; `edits.collection` is applied by the importer.
    public func applying(_ edits: SheetEdits, highlight: String?) -> Item {
        var item = self
        if let type = edits.type { item.type = type }
        if let title = edits.title { item.title = title }
        if let note = edits.note { item.note = note }
        if let favorite = edits.favorite { item.favorite = favorite }
        var tags = item.tags
        for tag in edits.addedTags where !tags.contains(tag) { tags.append(tag) }
        item.tags = tags.filter { !edits.removedTags.contains($0) }
        if let highlight, !item.highlights.contains(highlight) { item.highlights.append(highlight) }
        return item
    }
}
