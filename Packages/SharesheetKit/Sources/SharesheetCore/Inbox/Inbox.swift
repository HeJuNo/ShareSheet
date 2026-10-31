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
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let directories = try fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var result: [(request: ShareRequest, directory: URL)] = []
        for directory in directories {
            let file = directory.appending(path: Self.requestFileName)
            guard let data = try? Data(contentsOf: file),
                let request = try? decoder.decode(ShareRequest.self, from: data)
            else { continue }
            result.append((request, directory))
        }
        return result.sorted { ($0.request.created, $0.request.id.uuidString) < ($1.request.created, $1.request.id.uuidString) }
    }

    public func remove(_ id: UUID) throws {
        let directory = root.appending(path: id.uuidString, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
}
