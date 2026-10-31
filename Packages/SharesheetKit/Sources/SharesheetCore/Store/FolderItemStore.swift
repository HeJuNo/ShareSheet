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
        self.worker = Worker(root: root, trash: trash, onPlaceholder: onPlaceholder)
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
    private let fm = FileManager.default

    init(root: URL, trash: any Trashing, onPlaceholder: @escaping @Sendable (URL) -> Void) {
        self.root = root
        self.trash = trash
        self.onPlaceholder = onPlaceholder
    }

    // MARK: Reading

    func listItems() throws -> [Item] {
        try scan(.root)
    }

    func item(_ id: ItemID) throws -> Item {
        try read(id)
    }

    func findItem(url: URL) throws -> Item? {
        let target = URLCleaner.clean(url)
        return try scan(.root).first { $0.url.map(URLCleaner.clean) == target }
    }

    func attachmentURL(_ relativePath: String) throws -> URL {
        let url = fileURL(relativePath)
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
            let slug = FileNamer.sanitize(draft.title)
            let ext = source.pathExtension
            image = try attach(from: source, preferredName: ext.isEmpty ? "\(slug)-preview" : "\(slug)-preview.\(ext)")
        }
        let name = FileNamer.uniqueName(
            base: FileNamer.sanitize(draft.title), ext: "md", existing: Set(try entries(at: collection)))
        let id = ItemID(relativePath: (collection.components + [name]).joined(separator: "/"))
        let item = Item(
            id: id, type: draft.type, url: draft.url, file: file, title: draft.title,
            description: draft.description, tags: draft.tags, favorite: draft.favorite,
            created: created, image: image, note: draft.note, content: draft.content,
            highlights: draft.highlights)
        try write(item)
        return item
    }

    func update(_ item: Item) throws -> Item {
        guard fm.fileExists(atPath: fileURL(item.id.relativePath).path) else {
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
        try coordinatedMove(from: fileURL(id.relativePath), to: fileURL(newID.relativePath))
        item.id = newID
        return item
    }

    func delete(_ id: ItemID) throws {
        let item = try read(id)
        let attachments = [item.file, item.image, item.screenshot, item.archive]
            .compactMap { $0 }
            .filter { $0.hasPrefix(Self.attachments + "/") }
        var inUse = Set<String>()
        if !attachments.isEmpty {
            for other in try scan(.root) where other.id != id {
                inUse.formUnion([other.file, other.image, other.screenshot, other.archive].compactMap { $0 })
            }
        }
        try trashFile(fileURL(id.relativePath))
        for path in Set(attachments) where !inUse.contains(path) {
            let url = fileURL(path)
            if fm.fileExists(atPath: url.path) { try trashFile(url) }
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
        let destination = fileURL("\(Self.attachments)/\(name)")
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
        guard !path.components.isEmpty, Self.isCollectionName(path.components[0]) else {
            throw StoreError.notFound(path.relativePath)
        }
        guard fm.fileExists(atPath: directoryURL(path).path) else {
            throw StoreError.notFound(path.relativePath)
        }
        let items = try scan(path)
        let isEmpty = try entries(at: path).isEmpty
        if !isEmpty && destination == nil { throw StoreError.collectionNotEmpty }
        if let destination {
            for item in items { _ = try move(item.id, to: destination) }
        }
        try trashFile(directoryURL(path))
    }

    // MARK: Scanning

    /// Items under `collection` (recursively), skipping reserved folders and unparseable files.
    private func scan(_ collection: CollectionPath) throws -> [Item] {
        var items: [Item] = []
        for name in try entries(at: collection) {
            if name.hasPrefix(".") && name.hasSuffix(".icloud") {
                onPlaceholder(directoryURL(collection).appending(path: name))
                continue
            }
            guard Self.isCollectionName(name) else { continue }
            if isDirectory(collection, name) {
                items.append(contentsOf: try scan(CollectionPath(components: collection.components + [name])))
            } else if name.hasSuffix(".md") {
                let id = ItemID(relativePath: (collection.components + [name]).joined(separator: "/"))
                if let item = try? read(id) { items.append(item) }
            }
        }
        return items
    }

    private func entries(at collection: CollectionPath) throws -> [String] {
        let url = directoryURL(collection)
        guard fm.fileExists(atPath: url.path) else { return [] }
        return try coordinated(reading: url) { try fm.contentsOfDirectory(atPath: $0.path) }
    }

    private func isDirectory(_ collection: CollectionPath, _ name: String) -> Bool {
        var isDir: ObjCBool = false
        let url = directoryURL(collection).appending(path: name)
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func isCollectionName(_ name: String) -> Bool {
        !name.hasPrefix(".") && !name.hasPrefix("_")
    }

    // MARK: File helpers

    private func fileURL(_ relativePath: String) -> URL {
        relativePath.split(separator: "/").reduce(root) { $0.appending(path: String($1)) }
    }

    private func directoryURL(_ path: CollectionPath) -> URL {
        fileURL(path.relativePath)
    }

    private func ensureDirectory(_ path: CollectionPath) throws {
        let url = directoryURL(path)
        guard !fm.fileExists(atPath: url.path) else { return }
        try coordinated(writing: url, options: []) { try fm.createDirectory(at: $0, withIntermediateDirectories: true) }
    }

    private func read(_ id: ItemID) throws -> Item {
        let url = fileURL(id.relativePath)
        guard fm.fileExists(atPath: url.path) else { throw StoreError.notFound(id.relativePath) }
        let text = try coordinated(reading: url) { try String(contentsOf: $0, encoding: .utf8) }
        return try ItemCodec.decode(text, id: id)
    }

    private func write(_ item: Item) throws {
        let url = fileURL(item.id.relativePath)
        let data = Data(ItemCodec.encode(item).utf8)
        try coordinated(writing: url, options: .forReplacing) { try data.write(to: $0, options: .atomic) }
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
