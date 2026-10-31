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

    /// Oldest first; directories without a readable `request.json` are skipped.
    public func pending() throws -> [(request: ShareRequest, directory: URL)] {
        try scan().requests
    }

    /// Like `pending()`, and counts directories whose `request.json` exists but cannot be decoded.
    /// Directories without `request.json` are still being written and are not counted.
    func scan() throws -> (requests: [(request: ShareRequest, directory: URL)], unreadable: Int) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return ([], 0) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let directories = try fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var result: [(request: ShareRequest, directory: URL)] = []
        var unreadable = 0
        for directory in directories {
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

    public func remove(_ id: UUID) throws {
        let directory = root.appending(path: id.uuidString, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
}

public enum InboxError: Error, Equatable {
    case invalidFileName(String)
}
