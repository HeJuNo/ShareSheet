import Foundation

/// Items as Markdown files in a folder tree (the iCloud Drive library). All file access is
/// coordinated, and mutations are serialised through an internal actor.
public final class FolderItemStore: ItemStore, TrashStore {
    private let root: URL
    private let worker: Worker

    public init(
        root: URL, trash: any Trashing = LibraryTrash(),
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
    public func create(
        _ draft: ItemDraft, in collection: CollectionPath, willWrite: @Sendable (ItemID) throws -> Void
    ) async throws -> Item {
        try await worker.create(draft, in: collection, willWrite: willWrite)
    }
    public func update(_ item: Item) async throws -> Item { try await worker.update(item) }
    public func modify(_ id: ItemID, _ transform: @Sendable (inout Item) throws -> Void) async throws -> Item {
        try await worker.modify(id, transform)
    }
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

    public func trashedItems() async throws -> [TrashedItem] { try await worker.trashedItems() }
    public func restore(_ id: String) async throws -> Item { try await worker.restore(id) }
    public func purge(_ id: String) async throws { try await worker.purge(id) }
    public func emptyTrash() async throws { try await worker.emptyTrash() }
    public func purgeTrash(olderThan date: Date) async throws -> Int { try await worker.purgeTrash(olderThan: date) }

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
    private static let attachments = LibraryLayout.attachmentsFolder
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
        if let url = regularFileURL(relativePath) { return url }
        // iCloud keeps an evicted file as `.<name>.icloud` next to where the file belongs.
        if let url = try? fileURL(relativePath), !url.lastPathComponent.isEmpty {
            let placeholder = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).icloud")
            if fm.fileExists(atPath: placeholder.path) {
                onPlaceholder(placeholder)
                throw StoreError.downloading(relativePath)
            }
        }
        throw StoreError.notFound(relativePath)
    }

    func collections() throws -> [CollectionPath] {
        var result: Set<CollectionPath> = [.unsorted]
        func walk(_ path: CollectionPath) throws {
            for name in try entries(at: path) where LibraryLayout.isCollectionName(name) && isDirectory(path, name) {
                let child = CollectionPath(components: path.components + [name])
                result.insert(child)
                try walk(child)
            }
        }
        try walk(.root)
        return result.sorted()
    }

    // MARK: Writing items

    func create(
        _ draft: ItemDraft, in collection: CollectionPath, willWrite announce: @Sendable (ItemID) throws -> Void
    ) throws -> Item {
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
            created: created, image: image, capture: draft.capture, note: draft.note, content: draft.content,
            highlights: draft.highlights)
        let base = FileNamer.sanitize(draft.title)
        // The name is re-picked when another process takes it between naming and writing.
        for _ in 0..<20 {
            let name = FileNamer.uniqueName(base: base, ext: "md", existing: Set(try entries(at: collection)))
            item.id = ItemID(relativePath: (collection.components + [name]).joined(separator: "/"))
            let url = try fileURL(item.id.relativePath)
            willWrite?(url)
            let id = item.id
            if try writeNew(item, to: url, willWrite: { try announce(id) }) { return item }
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

    /// Read, transform and write happen inside one coordinated write, so neither another mutation of this store
    /// nor another process (the share extension) can write the file in between.
    func modify(_ id: ItemID, _ transform: @Sendable (inout Item) throws -> Void) throws -> Item {
        let url = try fileURL(id.relativePath)
        guard fm.fileExists(atPath: url.path) else { throw StoreError.notFound(id.relativePath) }
        return try coordinated(writing: url, options: .forMerging) { target in
            // Read directly: a second coordinator on the same file inside this block could deadlock.
            guard fm.fileExists(atPath: target.path) else { throw StoreError.notFound(id.relativePath) }
            let original = try ItemCodec.decode(try String(contentsOf: target, encoding: .utf8), id: id)
            var item = original
            try transform(&item)
            item.id = original.id
            item.created = Self.wholeSeconds(item.created)
            guard item != original else { return original }
            try Data(ItemCodec.encode(item).utf8).write(to: target, options: .atomic)
            return item
        }
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
        let attachments = Self.attachmentPaths(of: item)
        var inUse = Set<String>()
        var scanIsComplete = true
        if !attachments.isEmpty {
            let scanned = try scan(.root)
            scanIsComplete = scanned.isComplete
            for other in scanned.items where other.id != id {
                inUse.formUnion(other.attachmentReferences)
            }
        }
        try trashFile(try fileURL(id.relativePath))
        // Unreadable or not-yet-downloaded items may still reference an attachment: keep it then.
        guard scanIsComplete else { return }
        for path in Set(attachments) where !inUse.contains(path) {
            guard let url = regularFileURL(path) else { continue }
            try trashFile(url)
        }
    }

    // MARK: Trash

    private var trashURL: URL { root.appending(path: LibraryTrash.folderName, directoryHint: .isDirectory) }

    private static func attachmentPaths(of item: Item) -> [String] {
        item.attachmentReferences.filter { $0.hasPrefix(attachments + "/") }
    }

    /// Trashed items by path inside the trash, with their file's modification date as the time of deletion.
    private func trashedEntries() throws -> [(id: String, item: Item, deletedAt: Date)] {
        guard fm.fileExists(atPath: trashURL.path) else { return [] }
        let base = trashURL.resolvingSymlinksInPath().path
        var found: [(String, Item, Date)] = []
        let walker = fm.enumerator(at: trashURL, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey])
        for case let url as URL in walker ?? NSEnumerator() {
            guard url.pathExtension == "md" else { continue }
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(base + "/") else { continue }
            let relative = String(path.dropFirst(base.count + 1))
            guard !relative.hasPrefix(Self.attachments + "/"),
                let text = try? coordinated(reading: url, { try String(contentsOf: $0, encoding: .utf8) }),
                let item = try? ItemCodec.decode(text, id: ItemID(relativePath: relative))
            else { continue }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            found.append((relative, item, date))
        }
        return found
    }

    func trashedItems() throws -> [TrashedItem] {
        try trashedEntries().sorted { $0.deletedAt > $1.deletedAt }
            .map { TrashedItem(id: $0.id, title: $0.item.title, deletedAt: $0.deletedAt) }
    }

    func restore(_ id: String) throws -> Item {
        guard let entry = try trashedEntries().first(where: { $0.id == id }) else { throw StoreError.notFound(id) }
        let relative = id as NSString
        let folder = CollectionPath(components: relative.deletingLastPathComponent.split(separator: "/").map(String.init))
        try ensureDirectory(folder)
        let name = FileNamer.uniqueName(
            base: (relative.lastPathComponent as NSString).deletingPathExtension, ext: "md",
            existing: Set(try entries(at: folder)))
        let newID = ItemID(relativePath: (folder.components + [name]).joined(separator: "/"))
        try coordinatedMove(from: trashURL.appending(path: id), to: try fileURL(newID.relativePath))
        for path in Self.attachmentPaths(of: entry.item) {
            let source = trashURL.appending(path: path), destination = root.appending(path: path)
            guard fm.fileExists(atPath: source.path), !fm.fileExists(atPath: destination.path) else { continue }
            try ensureDirectory(CollectionPath(components: [Self.attachments]))
            try coordinatedMove(from: source, to: destination)
        }
        pruneEmptyTrashFolders()
        var item = entry.item
        item.id = newID
        return item
    }

    func purge(_ id: String) throws {
        guard fm.fileExists(atPath: trashURL.appending(path: id).path) else { throw StoreError.notFound(id) }
        try removeFromTrash(trashURL.appending(path: id))
        try cleanTrash()
    }

    func emptyTrash() throws {
        guard fm.fileExists(atPath: trashURL.path) else { return }
        for name in try fm.contentsOfDirectory(atPath: trashURL.path) { try removeFromTrash(trashURL.appending(path: name)) }
    }

    func purgeTrash(olderThan date: Date) throws -> Int {
        let old = try trashedEntries().filter { $0.deletedAt < date }
        for entry in old { try removeFromTrash(trashURL.appending(path: entry.id)) }
        if !old.isEmpty { try cleanTrash() }
        return old.count
    }

    private func removeFromTrash(_ url: URL) throws {
        try coordinated(writing: url, options: .forDeleting) { try fm.removeItem(at: $0) }
    }

    /// Removes trashed attachments no trashed item refers to any more, and folders left empty.
    private func cleanTrash() throws {
        let used = Set(try trashedEntries().flatMap { Self.attachmentPaths(of: $0.item) })
        let folder = trashURL.appending(path: Self.attachments)
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where !used.contains("\(Self.attachments)/\(name)") {
            try removeFromTrash(folder.appending(path: name))
        }
        pruneEmptyTrashFolders()
    }

    private func pruneEmptyTrashFolders() {
        guard let walker = fm.enumerator(at: trashURL, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        let folders = walker.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        for folder in folders.sorted(by: { $0.path.count > $1.path.count })
        where ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? ["x"]).isEmpty {
            try? fm.removeItem(at: folder)
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
        guard let first = path.components.first, LibraryLayout.isCollectionName(first) else {
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
            guard LibraryLayout.isCollectionName(name) else { continue }
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

    // MARK: File helpers

    /// Resolves a library-relative path; rejects empty, absolute and `..`/`.` components.
    private func fileURL(_ relativePath: String) throws -> URL {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !relativePath.hasPrefix("/"), !parts.contains(where: { $0 == ".." || $0 == "." }) else {
            throw StoreError.notFound(relativePath)
        }
        return parts.filter { !$0.isEmpty }.reduce(root) { $0.appending(path: $1) }
    }

    /// The URL of an existing regular file; nil for a path with an empty last component (`_attachments/`),
    /// a directory, or a missing file.
    private func regularFileURL(_ relativePath: String) -> URL? {
        guard let last = relativePath.split(separator: "/", omittingEmptySubsequences: false).last, !last.isEmpty,
            let url = try? fileURL(relativePath)
        else { return nil }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return url
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
    private func writeNew(_ item: Item, to url: URL, willWrite: () throws -> Void) throws -> Bool {
        let data = Data(ItemCodec.encode(item).utf8)
        return try coordinated(writing: url, options: []) { target in
            guard !fm.fileExists(atPath: target.path) else { return false }
            try willWrite()
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
