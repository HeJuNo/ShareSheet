import Foundation

/// Items as Markdown files in a folder tree (the iCloud Drive library). All file access is
/// coordinated, and mutations are serialised through an internal actor.
public final class FolderItemStore: ItemStore {
    private let root: URL
    private let worker: Worker

    public init(
        root: URL, trash: any Trashing = SystemTrash(),
        onPlaceholder: @escaping @Sendable (URL) -> Void = { _ in }
    ) {
        self.root = root
        self.worker = Worker(root: root, trash: trash, onPlaceholder: onPlaceholder, willWrite: nil)
    }

    /// Test seam: `willWrite` runs after a new item's file name is chosen and before it is written.
    init(root: URL, trash: any Trashing, willWrite: @escaping @Sendable (URL) -> Void) {
        self.root = root
        self.worker = Worker(root: root, trash: trash, onPlaceholder: { _ in }, willWrite: willWrite)
    }

    public func listItems() async throws -> [Item] { try await worker.listItems() }
    public func item(_ id: ItemID) async throws -> Item { try await worker.item(id) }
    public func findItem(url: URL) async throws -> Item? { try await worker.findItem(url: url) }
    public func create(_ draft: ItemDraft, in collection: CollectionPath) async throws -> Item {
        try await worker.create(draft, in: collection)
    }
    public func update(_ item: Item) async throws -> Item { try await worker.update(item) }
    public func move(_ id: ItemID, to collection: CollectionPath) async throws -> Item {
        try await worker.move(id, to: collection)
    }
    public func delete(_ id: ItemID) async throws { try await worker.delete(id) }
    public func addAttachment(from source: URL, preferredName: String) async throws -> String {
        try await worker.addAttachment(from: source, preferredName: preferredName)
    }
    public func attachmentURL(_ relativePath: String) async throws -> URL {
        try await worker.attachmentURL(relativePath)
    }
    public func collections() async throws -> [CollectionPath] { try await worker.collections() }
    public func createCollection(named name: String, in parent: CollectionPath) async throws -> CollectionPath {
        try await worker.createCollection(named: name, in: parent)
    }
    public func deleteCollection(_ path: CollectionPath, moveItemsTo destination: CollectionPath?) async throws {
        try await worker.deleteCollection(path, moveItemsTo: destination)
    }

    public func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let presenter = RootPresenter(root: root) { continuation.yield() }
            NSFileCoordinator.addFilePresenter(presenter)
            continuation.onTermination = { _ in NSFileCoordinator.removeFilePresenter(presenter) }
        }
    }
}

private final class RootPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()
    private let onChange: @Sendable () -> Void

    init(root: URL, onChange: @escaping @Sendable () -> Void) {
        presentedItemURL = root
        self.onChange = onChange
        super.init()
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
    }

    func presentedSubitemDidChange(at url: URL) { onChange() }
    func presentedItemDidChange() { onChange() }
}

private actor Worker {
    private static let attachments = "_attachments"
    private let root: URL
    private let trash: any Trashing
    private let onPlaceholder: @Sendable (URL) -> Void
    private let willWrite: (@Sendable (URL) -> Void)?
    private let fm = FileManager.default

    init(
        root: URL, trash: any Trashing, onPlaceholder: @escaping @Sendable (URL) -> Void,
        willWrite: (@Sendable (URL) -> Void)?
    ) {
        self.root = root
        self.trash = trash
        self.onPlaceholder = onPlaceholder
        self.willWrite = willWrite
    }

    // MARK: Reading

    func listItems() throws -> [Item] {
        try scan(.root).items
    }

    func item(_ id: ItemID) throws -> Item {
        try read(id)
    }

    func findItem(url: URL) throws -> Item? {
        let target = URLCleaner.clean(url)
        return try scan(.root).items.first { $0.url.map(URLCleaner.clean) == target }
    }

    func attachmentURL(_ relativePath: String) throws -> URL {
        let url = try fileURL(relativePath)
        guard fm.fileExists(atPath: url.path) else { throw StoreError.notFound(relativePath) }
        return url
    }

    func collections() throws -> [CollectionPath] {
        var result: Set<CollectionPath> = [.unsorted]
        func walk(_ path: CollectionPath) throws {
            for name in try entries(at: path) where Self.isCollectionName(name) && isDirectory(path, name) {
                let child = CollectionPath(components: path.components + [name])
                result.insert(child)
                try walk(child)
            }
        }
        try walk(.root)
        return result.sorted()
    }

    // MARK: Writing items

    func create(_ draft: ItemDraft, in collection: CollectionPath) throws -> Item {
        try ensureDirectory(collection)
        let created = Self.wholeSeconds(draft.created)
        var file: String?
        var image: String?
        if let source = draft.fileSource {
            file = try attach(from: source, preferredName: source.lastPathComponent)
        }
        if let source = draft.previewImageSource {
            let slug = FileNamer.sanitize(draft.title).lowercased().replacingOccurrences(of: " ", with: "-")
            let ext = source.pathExtension
            image = try attach(from: source, preferredName: ext.isEmpty ? "\(slug)-preview" : "\(slug)-preview.\(ext)")
        }
        var item = Item(
            id: ItemID(relativePath: ""), type: draft.type, url: draft.url, file: file, title: draft.title,
            description: draft.description, tags: draft.tags, favorite: draft.favorite,
            created: created, image: image, note: draft.note, content: draft.content,
            highlights: draft.highlights)
        let base = FileNamer.sanitize(draft.title)
        // The name is re-picked when another process takes it between naming and writing.
        for _ in 0..<20 {
            let name = FileNamer.uniqueName(base: base, ext: "md", existing: Set(try entries(at: collection)))
            item.id = ItemID(relativePath: (collection.components + [name]).joined(separator: "/"))
            let url = try fileURL(item.id.relativePath)
            willWrite?(url)
            if try writeNew(item, to: url) { return item }
        }
        throw StoreError.unavailable
    }

    func update(_ item: Item) throws -> Item {
        guard fm.fileExists(atPath: try fileURL(item.id.relativePath).path) else {
            throw StoreError.notFound(item.id.relativePath)
        }
        var item = item
        item.created = Self.wholeSeconds(item.created)
        try write(item)
        return item
    }

    func move(_ id: ItemID, to collection: CollectionPath) throws -> Item {
        var item = try read(id)
        if id.collection == collection { return item }
        try ensureDirectory(collection)
        let stem = (id.relativePath as NSString).lastPathComponent
        let base = (stem as NSString).deletingPathExtension
        let name = FileNamer.uniqueName(base: base, ext: "md", existing: Set(try entries(at: collection)))
        let newID = ItemID(relativePath: (collection.components + [name]).joined(separator: "/"))
        try coordinatedMove(from: try fileURL(id.relativePath), to: try fileURL(newID.relativePath))
        item.id = newID
        return item
    }

    func delete(_ id: ItemID) throws {
        let item = try read(id)
        let attachments = [item.file, item.image, item.screenshot, item.archive]
            .compactMap { $0 }
            .filter { $0.hasPrefix(Self.attachments + "/") }
        var inUse = Set<String>()
        var scanIsComplete = true
        if !attachments.isEmpty {
            let scanned = try scan(.root)
            scanIsComplete = scanned.isComplete
            for other in scanned.items where other.id != id {
                inUse.formUnion([other.file, other.image, other.screenshot, other.archive].compactMap { $0 })
            }
        }
        try trashFile(try fileURL(id.relativePath))
        // Unreadable or not-yet-downloaded items may still reference an attachment: keep it then.
        guard scanIsComplete else { return }
        for path in Set(attachments) where !inUse.contains(path) {
            guard let url = try? fileURL(path), fm.fileExists(atPath: url.path) else { continue }
            try trashFile(url)
        }
    }

    // MARK: Attachments

    func addAttachment(from source: URL, preferredName: String) throws -> String {
        try attach(from: source, preferredName: preferredName)
    }

    private func attach(from source: URL, preferredName: String) throws -> String {
        let folder = CollectionPath(components: [Self.attachments])
        try ensureDirectory(folder)
        let ext = (preferredName as NSString).pathExtension
        let stem = FileNamer.sanitize((preferredName as NSString).deletingPathExtension)
        let name = FileNamer.uniqueName(base: stem, ext: ext, existing: Set(try entries(at: folder)))
        let destination = try fileURL("\(Self.attachments)/\(name)")
        try coordinatedCopy(from: source, to: destination)
        return "\(Self.attachments)/\(name)"
    }

    // MARK: Collections

    func createCollection(named name: String, in parent: CollectionPath) throws -> CollectionPath {
        try ensureDirectory(parent)
        let unique = FileNamer.uniqueName(
            base: FileNamer.sanitize(name), ext: "", existing: Set(try entries(at: parent)))
        let path = CollectionPath(components: parent.components + [unique])
        try ensureDirectory(path)
        return path
    }

    func deleteCollection(_ path: CollectionPath, moveItemsTo destination: CollectionPath?) throws {
        guard let first = path.components.first, Self.isCollectionName(first) else {
            throw StoreError.notFound(path.relativePath)
        }
        guard path != .unsorted else { throw StoreError.unavailable }
        let url = try directoryURL(path)
        guard fm.fileExists(atPath: url.path) else { throw StoreError.notFound(path.relativePath) }
        if let destination {
            let inside = destination.components.starts(with: path.components)
            guard !inside else { throw StoreError.unavailable }
        }
        if try hasContent(path) {
            guard let destination else { throw StoreError.collectionNotEmpty }
            // Items of nested collections are flattened into the destination.
            for item in try scan(path).items { _ = try move(item.id, to: destination) }
            // Anything left (unparseable, not downloaded, other files) must not be trashed with the folder.
            if try hasContent(path) { throw StoreError.collectionNotEmpty }
        }
        try trashFile(url)
    }

    /// True when the folder (recursively) holds a visible file or an iCloud placeholder.
    private func hasContent(_ path: CollectionPath) throws -> Bool {
        for name in try entries(at: path) {
            if name.hasPrefix(".") && name.hasSuffix(".icloud") { return true }
            if name.hasPrefix(".") { continue }
            if isDirectory(path, name) {
                if try hasContent(CollectionPath(components: path.components + [name])) { return true }
            } else {
                return true
            }
        }
        return false
    }

    // MARK: Scanning

    /// Items under `collection` (recursively), skipping reserved folders and unparseable files.
    /// `isComplete` is false when a placeholder or unparseable `.md` was met.
    private func scan(_ collection: CollectionPath) throws -> (items: [Item], isComplete: Bool) {
        var items: [Item] = []
        var isComplete = true
        for name in try entries(at: collection) {
            if name.hasPrefix(".") && name.hasSuffix(".icloud") {
                onPlaceholder(try directoryURL(collection).appending(path: name))
                isComplete = false
                continue
            }
            guard Self.isCollectionName(name) else { continue }
            if isDirectory(collection, name) {
                let nested = try scan(CollectionPath(components: collection.components + [name]))
                items.append(contentsOf: nested.items)
                isComplete = isComplete && nested.isComplete
            } else if name.hasSuffix(".md") {
                let id = ItemID(relativePath: (collection.components + [name]).joined(separator: "/"))
                if let item = try? read(id) { items.append(item) } else { isComplete = false }
            }
        }
        return (items, isComplete)
    }

    private func entries(at collection: CollectionPath) throws -> [String] {
        let url = try directoryURL(collection)
        guard fm.fileExists(atPath: url.path) else { return [] }
        return try coordinated(reading: url) { try fm.contentsOfDirectory(atPath: $0.path) }
    }

    private func isDirectory(_ collection: CollectionPath, _ name: String) -> Bool {
        var isDir: ObjCBool = false
        guard let url = try? directoryURL(collection).appending(path: name) else { return false }
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func isCollectionName(_ name: String) -> Bool {
        name != attachments && !name.hasPrefix(".")
    }

    // MARK: File helpers

    /// Resolves a library-relative path; rejects empty, absolute and `..`/`.` components.
    private func fileURL(_ relativePath: String) throws -> URL {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !relativePath.hasPrefix("/"), !parts.contains(where: { $0 == ".." || $0 == "." }) else {
            throw StoreError.notFound(relativePath)
        }
        return parts.filter { !$0.isEmpty }.reduce(root) { $0.appending(path: $1) }
    }

    private func directoryURL(_ path: CollectionPath) throws -> URL {
        try fileURL(path.relativePath)
    }

    private func ensureDirectory(_ path: CollectionPath) throws {
        let url = try directoryURL(path)
        guard !fm.fileExists(atPath: url.path) else { return }
        try coordinated(writing: url, options: []) { try fm.createDirectory(at: $0, withIntermediateDirectories: true) }
    }

    private func read(_ id: ItemID) throws -> Item {
        let url = try fileURL(id.relativePath)
        guard fm.fileExists(atPath: url.path) else { throw StoreError.notFound(id.relativePath) }
        let text = try coordinated(reading: url) { try String(contentsOf: $0, encoding: .utf8) }
        return try ItemCodec.decode(text, id: id)
    }

    private func write(_ item: Item) throws {
        let url = try fileURL(item.id.relativePath)
        let data = Data(ItemCodec.encode(item).utf8)
        try coordinated(writing: url, options: .forReplacing) { try data.write(to: $0, options: .atomic) }
    }

    /// Writes a new file; returns false (writing nothing) when the file already exists.
    private func writeNew(_ item: Item, to url: URL) throws -> Bool {
        let data = Data(ItemCodec.encode(item).utf8)
        return try coordinated(writing: url, options: []) { target in
            guard !fm.fileExists(atPath: target.path) else { return false }
            try data.write(to: target, options: .atomic)
            return true
        }
    }

    private func trashFile(_ url: URL) throws {
        try coordinated(writing: url, options: .forDeleting) { try trash.trash($0, libraryRoot: root) }
    }

    private func coordinatedMove(from source: URL, to destination: URL) throws {
        var error: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: source, options: .forMoving, writingItemAt: destination, options: .forReplacing, error: &error
        ) { src, dst in
            result = Result { try fm.moveItem(at: src, to: dst) }
        }
        if let error { throw error }
        try result?.get()
    }

    private func coordinatedCopy(from source: URL, to destination: URL) throws {
        var error: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: source, options: [], writingItemAt: destination, options: .forReplacing, error: &error
        ) { src, dst in
            result = Result { try fm.copyItem(at: src, to: dst) }
        }
        if let error { throw error }
        try result?.get()
    }

    private func coordinated<T>(reading url: URL, _ body: (URL) throws -> T) throws -> T {
        var error: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &error) { url in
            result = Result { try body(url) }
        }
        if let error { throw error }
        return try result!.get()
    }

    private func coordinated<T>(
        writing url: URL, options: NSFileCoordinator.WritingOptions, _ body: (URL) throws -> T
    ) throws -> T {
        var error: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: options, error: &error) { url in
            result = Result { try body(url) }
        }
        if let error { throw error }
        return try result!.get()
    }

    private static func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }
}
