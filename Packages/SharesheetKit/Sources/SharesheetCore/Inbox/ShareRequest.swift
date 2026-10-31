import Foundation

/// The fields the user changed in the share sheet; everything else stays nil or empty.
public struct SheetEdits: Codable, Equatable, Sendable {
    public var type: ItemType?
    public var title: String?
    public var note: String?
    public var favorite: Bool?
    public var collection: CollectionPath?
    public var addedTags: [String]
    public var removedTags: [String]

    public init(
        type: ItemType? = nil, title: String? = nil, note: String? = nil, favorite: Bool? = nil,
        collection: CollectionPath? = nil, addedTags: [String] = [], removedTags: [String] = []
    ) {
        self.type = type
        self.title = title
        self.note = note
        self.favorite = favorite
        self.collection = collection
        self.addedTags = addedTags
        self.removedTags = removedTags
    }
}

public struct ShareEntry: Codable, Sendable {
    public var type: ItemType
    public var url: URL?
    public var title: String
    public var description: String?
    public var content: String?
    public var highlight: String?
    /// File inside the request's inbox directory.
    public var fileName: String?
    public var previewImageName: String?

    public init(
        type: ItemType, url: URL? = nil, title: String, description: String? = nil,
        content: String? = nil, highlight: String? = nil, fileName: String? = nil,
        previewImageName: String? = nil
    ) {
        self.type = type
        self.url = url
        self.title = title
        self.description = description
        self.content = content
        self.highlight = highlight
        self.fileName = fileName
        self.previewImageName = previewImageName
    }
}

public struct ShareRequest: Codable, Sendable, Identifiable {
    public var id: UUID
    public var created: Date
    public var entries: [ShareEntry]
    /// Target collection, or the parent of the new collection.
    public var collection: CollectionPath
    /// Set when `entries.count > 1`.
    public var newCollectionName: String?
    public var tags: [String]
    public var note: String
    public var favorite: Bool
    /// Re-share of a known URL.
    public var existingItem: ItemID?
    public var edits: SheetEdits?

    public init(
        id: UUID = UUID(), created: Date = Date(), entries: [ShareEntry], collection: CollectionPath,
        newCollectionName: String? = nil, tags: [String] = [], note: String = "",
        favorite: Bool = false, existingItem: ItemID? = nil, edits: SheetEdits? = nil
    ) {
        self.id = id
        self.created = created
        self.entries = entries
        self.collection = collection
        self.newCollectionName = newCollectionName
        self.tags = tags
        self.note = note
        self.favorite = favorite
        self.existingItem = existingItem
        self.edits = edits
    }
}
