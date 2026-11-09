import Foundation

/// Folder names the library reserves for itself.
public enum LibraryLayout {
    public static let attachmentsFolder = "_attachments"

    /// False for the attachments folder and hidden folders, which are never collections.
    public static func isCollectionName(_ name: String) -> Bool {
        name != attachmentsFolder && !name.hasPrefix(".")
    }
}

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

/// A value read from a document by a rule.
public enum FieldValue: Equatable, Sendable {
    case number(Double)
    case date(Date)
    case text(String)
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
    /// True when `created` was set by hand; rules never change such a date.
    public var createdManual: Bool
    /// Fields set by rules from the document text, by name.
    public var fields: [String: FieldValue]
    /// True when the title was edited by hand; rules never change such a title.
    public var titleManual: Bool
    /// Names of fields changed by hand, and of fields deleted by hand; rules leave both alone.
    public var fieldsManual: Set<String>
    public var fieldsDeleted: Set<String>
    public var image: String?
    public var screenshot: String?
    /// The page in its own dark appearance, captured only for pages that have one.
    public var screenshotDark: String?
    public var archive: String?

    /// Every attachment path this item refers to, library-relative.
    public var attachmentReferences: [String] {
        [file, image, screenshot, screenshotDark, archive].compactMap { $0 }
    }

    /// Replaces attachment paths (`old` -> `new`); paths not in `map` stay.
    public mutating func remapAttachments(_ map: [String: String]) {
        func mapped(_ path: String?) -> String? { path.map { map[$0] ?? $0 } }
        file = mapped(file)
        image = mapped(image)
        screenshot = mapped(screenshot)
        screenshotDark = mapped(screenshotDark)
        archive = mapped(archive)
    }

    /// Where each attachment of this item went in `other` (the same item after a move).
    public func attachmentMoves(to other: Item) -> [AttachmentMove] {
        let pairs = [(file, other.file), (image, other.image), (screenshot, other.screenshot),
            (screenshotDark, other.screenshotDark), (archive, other.archive)]
        return pairs.compactMap { old, new in
            guard let old, let new, old != new else { return nil }
            return AttachmentMove(from: old, to: new)
        }
    }
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
        createdManual: Bool = false, fields: [String: FieldValue] = [:], titleManual: Bool = false,
        fieldsManual: Set<String> = [], fieldsDeleted: Set<String> = [], image: String? = nil, screenshot: String? = nil, screenshotDark: String? = nil, archive: String? = nil,
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
        self.createdManual = createdManual
        self.fields = fields
        self.titleManual = titleManual
        self.fieldsManual = fieldsManual
        self.fieldsDeleted = fieldsDeleted
        self.image = image
        self.screenshot = screenshot
        self.screenshotDark = screenshotDark
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
