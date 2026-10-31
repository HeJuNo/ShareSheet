import Foundation
import SharesheetCore
import UniformTypeIdentifiers

/// Turns the extension's input items into `SharedInput`s. Files are copied by URL into a temp
/// directory inside the App Group and never read into memory. The copying runs in the providers'
/// callbacks, off the main thread.
@MainActor
struct SharedPayloadLoader {
    /// Holds this share's file copies; delete it once the share is enqueued or cancelled.
    let temporaryDirectory: URL

    init() {
        let base = AppGroup.containerURL() ?? FileManager.default.temporaryDirectory
        temporaryDirectory = base
            .appending(path: "Tmp", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    /// The loaded inputs and how many attachments could not be read.
    func load(_ items: [NSExtensionItem]) async -> (inputs: [SharedInput], failed: Int) {
        var inputs: [SharedInput] = []
        var failed = 0
        for item in items {
            let providers = item.attachments ?? []
            if let safari = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier) }),
               let page = try? await loadSafariPage(safari) {
                inputs.append(page)
                continue
            }
            for provider in providers {
                // One unreadable attachment must not lose the others.
                do {
                    if let input = try await load(provider) { inputs.append(input) }
                } catch {
                    failed += 1
                }
            }
        }
        return (inputs, failed)
    }

    // MARK: Attachments

    /// Returns nil for attachments that are not items of their own (Safari's property list).
    private func load(_ provider: NSItemProvider) async throws -> SharedInput? {
        let kind = PayloadClassifier.kind(
            registeredTypes: provider.registeredTypeIdentifiers, suggestedName: provider.suggestedName)
        switch kind {
        case .skip:
            return nil
        case .fileURL:
            return try await loadFileURL(provider)
        case .url:
            guard let url = try await loadObject(URL.self, from: provider) else { throw LoadError.empty }
            return .url(url, pageTitle: nil, selection: nil)
        case .text:
            guard let text = try await loadObject(String.self, from: provider) else { throw LoadError.empty }
            if let url = Self.webURL(text) { return .url(url, pageTitle: nil, selection: nil) }
            if PayloadClassifier.isTooLargeForText(text) { return try saveText(text, name: provider.suggestedName) }
            return .text(text)
        case .file:
            guard let type = provider.registeredContentTypes.first else { throw LoadError.empty }
            return try await loadFile(provider, type: type)
        }
    }

    /// Text too large for an in-memory snippet becomes a `.txt` file.
    private func saveText(_ text: String, name: String?) throws -> SharedInput {
        let directory = makeFileDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = (name.flatMap { $0.isEmpty ? nil : $0.replacingOccurrences(of: "/", with: "-") } ?? "Text") + ".txt"
        let destination = directory.appending(path: fileName)
        try text.write(to: destination, atomically: true, encoding: .utf8)
        return .file(destination, contentType: .plainText, name: fileName)
    }

    /// Safari's preprocessing results: `url`, `title`, `selection` and `description` from Preprocess.js.
    private func loadSafariPage(_ provider: NSItemProvider) async throws -> SharedInput? {
        let page: (url: URL, title: String?, selection: String?, description: String?)? = try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier, options: nil) { item, error in
                if let error { return continuation.resume(throwing: error) }
                let results = (item as? NSDictionary)?[NSExtensionJavaScriptPreprocessingResultsKey] as? NSDictionary
                guard let string = results?["url"] as? String, let url = URL(string: string) else {
                    return continuation.resume(returning: nil)
                }
                continuation.resume(returning: (
                    url, results?["title"] as? String, results?["selection"] as? String,
                    results?["description"] as? String))
            }
        }
        return page.map { .url($0.url, pageTitle: $0.title, selection: $0.selection, description: $0.description) }
    }

    private func loadObject<T: _ObjectiveCBridgeable & Sendable>(_ type: T.Type, from provider: NSItemProvider) async throws -> T?
    where T._ObjectiveCType: NSItemProviderReading {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: type) { value, error in
                if let error { return continuation.resume(throwing: error) }
                continuation.resume(returning: value)
            }
        }
    }

    /// A `public.url` pointing at a local file: copy the file while the provider grants access.
    private func loadFileURL(_ provider: NSItemProvider) async throws -> SharedInput? {
        let destinationDirectory = makeFileDirectory()
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                if let error { return continuation.resume(throwing: error) }
                guard let url, url.isFileURL else { return continuation.resume(throwing: LoadError.empty) }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let name = url.lastPathComponent
                    let destination = destinationDirectory.appending(path: name)
                    try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: destination)
                    let type = UTType(filenameExtension: url.pathExtension) ?? .data
                    continuation.resume(returning: .file(destination, contentType: type, name: name))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Any other attachment: the system hands over a file that is only valid inside the callback.
    private func loadFile(_ provider: NSItemProvider, type: UTType) async throws -> SharedInput? {
        let destinationDirectory = makeFileDirectory()
        let suggestedName = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
                if let error { return continuation.resume(throwing: error) }
                guard let url else { return continuation.resume(throwing: LoadError.empty) }
                do {
                    let name = Self.fileName(suggested: suggestedName, source: url, type: type)
                    let destination = destinationDirectory.appending(path: name)
                    try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: destination)
                    continuation.resume(returning: .file(destination, contentType: type, name: name))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: Helpers

    /// One subdirectory per file, so equal names from different attachments never collide.
    private func makeFileDirectory() -> URL {
        temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    private nonisolated static func fileName(suggested: String?, source: URL, type: UTType) -> String {
        var name = suggested?.replacingOccurrences(of: "/", with: "-") ?? source.lastPathComponent
        if name.isEmpty { name = source.lastPathComponent }
        if (name as NSString).pathExtension.isEmpty {
            let ext = source.pathExtension.isEmpty ? (type.preferredFilenameExtension ?? "") : source.pathExtension
            if !ext.isEmpty { name += ".\(ext)" }
        }
        return name
    }

    /// Text that is nothing but an http(s) URL.
    private nonisolated static func webURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil
        else { return nil }
        return url
    }
}

private enum LoadError: Error {
    case empty
}
