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

extension ItemDraft {
    static func fixture(
        type: ItemType = .link,
        url: URL? = URL(string: "https://a.b/")!,
        title: String = "T",
        description: String? = nil,
        tags: [String] = [],
        favorite: Bool = false,
        note: String = "",
        content: String? = nil,
        highlights: [String] = [],
        created: Date = ISO8601DateFormatter().date(from: "2026-10-31T20:44:00Z")!,
        fileSource: URL? = nil,
        previewImageSource: URL? = nil
    ) -> ItemDraft {
        ItemDraft(
            type: type, url: url, title: title, description: description, tags: tags,
            favorite: favorite, note: note, content: content, highlights: highlights,
            created: created, fileSource: fileSource, previewImageSource: previewImageSource)
    }
}

/// Records trashed URLs and moves the files into a temp dir instead of deleting them.
final class RecordingTrash: Trashing, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private let bin = FileManager.default.temporaryDirectory.appending(path: "trash-\(UUID().uuidString)")

    var trashed: [URL] { lock.withLock { urls } }

    func trash(_ url: URL, libraryRoot: URL) throws {
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: bin.appending(path: UUID().uuidString + "-" + url.lastPathComponent))
        lock.withLock { urls.append(url) }
    }
}

func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "sharesheet-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func makeStore(
    trash: RecordingTrash = RecordingTrash(),
    onPlaceholder: @escaping @Sendable (URL) -> Void = { _ in }
) throws -> (FolderItemStore, URL) {
    let root = try makeTempDirectory()
    return (FolderItemStore(root: root, trash: trash, onPlaceholder: onPlaceholder), root)
}

func tempFile(named name: String, bytes: Int) throws -> URL {
    let url = try makeTempDirectory().appending(path: name)
    try Data(repeating: 0x41, count: bytes).write(to: url)
    return url
}
