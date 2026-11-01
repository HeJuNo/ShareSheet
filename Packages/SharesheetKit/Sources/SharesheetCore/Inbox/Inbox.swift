import Foundation

/// App Group folder holding one directory per pending share: `<root>/<id>/request.json` plus its files.
public struct Inbox: Sendable {
    static let requestFileName = "request.json"
    private let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Writes `request.json` last, so a crash mid-copy never leaves a request `pending()` would pick up.
    public func enqueue(_ request: ShareRequest, files: [String: URL]) throws {
        let fm = FileManager.default
        let reserved = [Self.requestFileName, InboxImporter.progressFileName]
        for name in files.keys
        where name.isEmpty || name.contains("/") || name.contains("..") || reserved.contains(name) {
            throw InboxError.invalidFileName(name)
        }
        let directory = root.appending(path: request.id.uuidString, directoryHint: .isDirectory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, source) in files {
            let destination = directory.appending(path: name)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.copyItem(at: source, to: destination)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(request).write(
            to: directory.appending(path: Self.requestFileName), options: .atomic)
    }

    /// Oldest first; directories without a readable `request.json` are skipped, and so are requests another
    /// process claimed less than `claimTimeout` ago.
    public func pending(now: Date = Date()) throws -> [(request: ShareRequest, directory: URL)] {
        try scan(now: now).requests
    }

    /// Like `pending()`, and counts directories whose `request.json` exists but cannot be decoded.
    /// Directories without `request.json` are still being written and are not counted.
    func scan(now: Date = Date()) throws -> (requests: [(request: ShareRequest, directory: URL)], unreadable: Int) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return ([], 0) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let directories = try fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var result: [(request: ShareRequest, directory: URL)] = []
        var unreadable = 0
        for directory in directories {
            if let claimed = Self.claimDate(of: directory), now.timeIntervalSince(claimed) < Self.claimTimeout {
                continue
            }
            let file = directory.appending(path: Self.requestFileName)
            guard fm.fileExists(atPath: file.path) else { continue }
            guard let data = try? Data(contentsOf: file),
                let request = try? decoder.decode(ShareRequest.self, from: data)
            else {
                unreadable += 1
                continue
            }
            result.append((request, directory))
        }
        let sorted = result.sorted { ($0.request.created, $0.request.id.uuidString) < ($1.request.created, $1.request.id.uuidString) }
        return (sorted, unreadable)
    }

    // MARK: Claiming

    /// A claim older than this is taken to belong to a process that died; another importer may take it over.
    static let claimTimeout: TimeInterval = 600
    private static let claimMarker = ".claimed-"

    /// Renames `<id>` (or a stale claim of it) to `<id>.claimed-<seconds>-<uuid>`. The rename is atomic, so of
    /// several processes claiming the same directory exactly one succeeds; the others get nil.
    func claim(_ directory: URL, now: Date) -> URL? {
        let base = Self.unclaimedName(directory.lastPathComponent)
        let seconds = Int(now.timeIntervalSince1970.rounded(.down))
        let claimed = root.appending(
            path: "\(base)\(Self.claimMarker)\(seconds)-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try FileManager.default.moveItem(at: directory, to: claimed)
            return claimed
        } catch {
            return nil
        }
    }

    /// Gives a claimed directory back under its original name, so the next import retries it.
    func release(_ claimed: URL) {
        let original = root.appending(path: Self.unclaimedName(claimed.lastPathComponent), directoryHint: .isDirectory)
        try? FileManager.default.moveItem(at: claimed, to: original)
    }

    func removeDirectory(_ directory: URL) throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private static func unclaimedName(_ name: String) -> String {
        guard let range = name.range(of: claimMarker) else { return name }
        return String(name[..<range.lowerBound])
    }

    private static func claimDate(of directory: URL) -> Date? {
        let name = directory.lastPathComponent
        guard let range = name.range(of: claimMarker) else { return nil }
        let seconds = name[range.upperBound...].prefix { $0.isNumber }
        // An unparseable claim counts as stale.
        guard let value = TimeInterval(seconds) else { return .distantPast }
        return Date(timeIntervalSince1970: value)
    }

    public func remove(_ id: UUID) throws {
        try removeDirectory(root.appending(path: id.uuidString, directoryHint: .isDirectory))
    }
}

public enum InboxError: Error, Equatable {
    case invalidFileName(String)
}
