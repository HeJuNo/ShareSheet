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
        // The unreadable attachments were this same post, so nothing is missing.
        if inputs.isEmpty, let url = Self.firstWebURL(in: items) {
            inputs.append(.url(url, pageTitle: nil, selection: nil))
            failed = 0
        } else if inputs.isEmpty, let text = Self.firstText(in: items) {
            // The share's own text, when its attachment cannot be read.
            inputs.append((try? textInput(text, name: nil)) ?? .text(text))
            failed = 0
        }
        return (inputs, failed)
    }

    /// The first non-blank text the sending app put in the share itself.
    private nonisolated static func firstText(in items: [NSExtensionItem]) -> String? {
        items.compactMap { $0.attributedContentText?.string }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Some apps share a post without a usable attachment and put its link only in the item's text.
    private nonisolated static func firstWebURL(in items: [NSExtensionItem]) -> URL? {
        let texts = items.flatMap { [$0.attributedContentText?.string, $0.attributedTitle?.string] }.compactMap { $0 }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for text in texts {
            let range = NSRange(text.startIndex..., in: text)
            for match in detector.matches(in: text, range: range) {
                if let url = match.url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
                    return url
                }
            }
        }
        return nil
    }

    /// Inputs typed or picked in the app: a link or text, and files, each copied like a shared attachment.
    func load(text: String, files: [URL]) -> (inputs: [SharedInput], failed: Int) {
        var inputs: [SharedInput] = []
        var failed = 0
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = Self.webURL(trimmed) {
            inputs.append(.url(url, pageTitle: nil, selection: nil))
        } else if !trimmed.isEmpty {
            inputs.append(PayloadClassifier.isTooLargeForText(trimmed)
                ? ((try? saveText(trimmed, name: nil)) ?? .text(trimmed)) : .text(trimmed))
        }
        for file in files {
            let directory = makeFileDirectory()
            let scoped = file.startAccessingSecurityScopedResource()
            defer { if scoped { file.stopAccessingSecurityScopedResource() } }
            do {
                let destination = directory.appending(path: file.lastPathComponent)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: file, to: destination)
                let type = UTType(filenameExtension: file.pathExtension) ?? .data
                inputs.append(.file(destination, contentType: type, name: file.lastPathComponent))
            } catch {
                failed += 1
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
            guard let text = try await loadText(provider) else { throw LoadError.empty }
            return try textInput(text, name: provider.suggestedName)
        case .file:
            guard let type = provider.registeredContentTypes.first else { throw LoadError.empty }
            return try await loadFile(provider, type: type)
        }
    }

    /// A link when the text is one, a file when it is too large for a snippet, else the snippet.
    private func textInput(_ text: String, name: String?) throws -> SharedInput {
        if let url = Self.webURL(text) { return .url(url, pageTitle: nil, selection: nil) }
        if PayloadClassifier.isTooLargeForText(text) { return try saveText(text, name: name) }
        return .text(text)
    }

    /// The usual route first. An attachment registered only as `public.plain-text` (or as raw data, a file, an
    /// NSString item) cannot be read as a `String` object, so each text type is then read as data, then as an item.
    private func loadText(_ provider: NSItemProvider) async throws -> String? {
        if let text = try? await loadObject(String.self, from: provider) { return text }
        for identifier in provider.registeredTypeIdentifiers where UTType(identifier)?.conforms(to: .text) == true {
            // The item first: for a provider built from an object, the data is its archive, not its text.
            if let text = await loadTextItem(provider, identifier) { return text }
            if let text = await loadTextData(provider, identifier) { return text }
        }
        return nil
    }

    private func loadTextData(_ provider: NSItemProvider, _ identifier: String) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
                continuation.resume(returning: data.flatMap(Self.decode))
            }
        }
    }

    private func loadTextItem(_ provider: NSItemProvider, _ identifier: String) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
                let text: String?
                switch item {
                case let value as String: text = value
                case let data as Data: text = Self.decode(data)
                case let url as URL where url.isFileURL: text = (try? Data(contentsOf: url)).flatMap(Self.decode)
                default: text = nil
                }
                continuation.resume(returning: text)
            }
        }
    }

    /// UTF-8, or UTF-16 when the data starts with a byte order mark; anything else is not text.
    private nonisolated static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16) }
        return String(data: data, encoding: .utf8)
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
