import Foundation
import UniformTypeIdentifiers

/// One thing handed to the share extension.
public enum SharedInput: Sendable {
    case url(URL, pageTitle: String?, selection: String?, description: String? = nil)
    case text(String)
    /// A local copy of a shared file; `name` is the original file name.
    case file(URL, contentType: UTType, name: String)
}

/// What the share sheet shows and edits.
public struct SheetState: Equatable, Sendable {
    public var type: ItemType
    public var title: String
    public var description: String?
    public var note: String
    /// Target collection, or the parent of the new collection for multi-item shares.
    public var collection: CollectionPath
    /// Set for multi-item shares.
    public var newCollectionName: String?
    public var tags: [String]
    public var favorite: Bool
    public var highlight: String?
    public var url: URL?

    public init(
        type: ItemType, title: String, description: String? = nil, note: String = "",
        collection: CollectionPath = .unsorted, newCollectionName: String? = nil, tags: [String] = [],
        favorite: Bool = false, highlight: String? = nil, url: URL? = nil
    ) {
        self.type = type
        self.title = title
        self.description = description
        self.note = note
        self.collection = collection
        self.newCollectionName = newCollectionName
        self.tags = tags
        self.favorite = favorite
        self.highlight = highlight
        self.url = url
    }
}

/// Pure logic behind the share sheet: the initial form state and the inbox request built from it.
public enum ShareRequestBuilder {
    public static let previewImageName = "preview.jpg"
    private static let titleLength = 80
    private static let reservedNames: Set<String> = ["request.json", "progress.json", previewImageName]

    /// Collapses the redundant attachments apps send with a link: the same URL twice (compared after
    /// cleaning) is kept once, and text sent along with links (and no files) is not an item of its own:
    /// it becomes the title of a single untitled link, otherwise it is returned as `note`.
    /// Several distinct links, or files, are kept as they are.
    public static func normalized(_ inputs: [SharedInput]) -> (inputs: [SharedInput], note: String?) {
        var result: [SharedInput] = []
        var seen: [URL: Int] = [:]
        for input in inputs {
            guard case .url(let url, let pageTitle, let selection, let description) = input else {
                result.append(input)
                continue
            }
            let key = URLCleaner.clean(url)
            if let index = seen[key], case .url(let first, let title, let firstSelection, let firstDescription) = result[index] {
                result[index] = .url(
                    first, pageTitle: title ?? pageTitle, selection: firstSelection ?? selection,
                    description: firstDescription ?? description)
            } else {
                seen[key] = result.count
                result.append(input)
            }
        }
        let hasFile = result.contains { if case .file = $0 { true } else { false } }
        guard !seen.isEmpty, !hasFile else { return (result, nil) }

        var texts: [String] = []
        result.removeAll { input in
            guard case .text(let text) = input else { return false }
            if let trimmed = nonBlank(text), !seen.keys.contains(where: { $0.absoluteString == trimmed }),
               URL(string: trimmed).map({ seen[URLCleaner.clean($0)] == nil }) ?? true {
                texts.append(trimmed)
            }
            return true
        }
        if result.count == 1, case .url(let url, nil, let selection, let description) = result[0], !texts.isEmpty {
            result[0] = .url(url, pageTitle: texts.removeFirst(), selection: selection, description: description)
        }
        return (result, texts.isEmpty ? nil : texts.joined(separator: "\n\n"))
    }

    public static func initialState(
        for inputs: [SharedInput], existing: Item?, now: Date, timeZone: TimeZone = .current
    ) -> SheetState {
        if inputs.count > 1 {
            return SheetState(
                type: preset(inputs[0]), title: "", collection: .root,
                newCollectionName: defaultCollectionName(now, timeZone: timeZone))
        }
        var state: SheetState
        switch inputs.first {
        case .url(let url, let pageTitle, let selection, let description):
            let cleaned = URLCleaner.clean(url)
            state = SheetState(
                type: ItemType.preset(for: cleaned),
                title: nonBlank(pageTitle) ?? cleaned.host ?? cleaned.absoluteString,
                description: nonBlank(description), highlight: nonBlank(selection), url: cleaned)
        case .text(let text):
            state = SheetState(type: .text, title: firstLine(text))
        case .file(_, let contentType, let name):
            state = SheetState(type: ItemType.preset(forContentType: contentType), title: stem(name))
        case nil:
            state = SheetState(type: .link, title: "")
        }
        if let existing {
            state.type = existing.type
            state.title = existing.title
            state.description = existing.description ?? state.description
            state.note = existing.note
            state.tags = existing.tags
            state.favorite = existing.favorite
            state.collection = existing.id.collection
        }
        return state
    }

    /// The request to enqueue and the files to copy into its inbox directory (inbox name → source).
    /// The request always carries the final sheet state, so a re-share whose item vanished is created
    /// correctly; `edits` hold only what the user changed.
    public static func request(
        from state: SheetState, initial: SheetState, inputs: [SharedInput], existing: Item?, id: UUID,
        now: Date, previewImage: URL? = nil
    ) -> (ShareRequest, files: [String: URL]) {
        var files: [String: URL] = [:]
        var taken = reservedNames
        var entries: [ShareEntry] = []
        let isSingle = inputs.count <= 1

        if isSingle {
            var entry = ShareEntry(type: state.type, url: state.url, title: state.title, description: state.description)
            switch inputs.first {
            case .text(let text):
                entry.url = nil
                entry.content = text
            case .file(let source, let contentType, let name):
                let fileName = inboxName(for: name, contentType: contentType, taken: &taken)
                files[fileName] = source
                entry.url = nil
                entry.fileName = fileName
            case .url, nil:
                entry.highlight = state.highlight
                if let previewImage {
                    files[previewImageName] = previewImage
                    entry.previewImageName = previewImageName
                }
            }
            entries.append(entry)
        } else {
            let typeOverride = state.type != initial.type ? state.type : nil
            for input in inputs {
                switch input {
                case .url(let url, let pageTitle, let selection, let description):
                    let cleaned = URLCleaner.clean(url)
                    entries.append(ShareEntry(
                        type: typeOverride ?? ItemType.preset(for: cleaned),
                        url: cleaned, title: nonBlank(pageTitle) ?? cleaned.host ?? cleaned.absoluteString,
                        description: nonBlank(description), highlight: nonBlank(selection)))
                case .text(let text):
                    entries.append(ShareEntry(type: typeOverride ?? .text, title: firstLine(text), content: text))
                case .file(let source, let contentType, let name):
                    let fileName = inboxName(for: name, contentType: contentType, taken: &taken)
                    files[fileName] = source
                    entries.append(ShareEntry(
                        type: typeOverride ?? ItemType.preset(forContentType: contentType),
                        title: stem(name), fileName: fileName))
                }
            }
        }

        var request = ShareRequest(
            id: id, created: now, entries: entries, collection: state.collection,
            newCollectionName: entries.count > 1
                ? (nonBlank(state.newCollectionName) ?? nonBlank(initial.newCollectionName)) : nil,
            tags: state.tags, note: state.note, favorite: state.favorite)
        if let existing, isSingle {
            request.existingItem = existing.id
            request.edits = edits(from: initial, to: state)
        }
        return (request, files)
    }

    // MARK: Helpers

    private static func edits(from initial: SheetState, to state: SheetState) -> SheetEdits {
        SheetEdits(
            type: state.type != initial.type ? state.type : nil,
            title: state.title != initial.title ? state.title : nil,
            note: state.note != initial.note ? state.note : nil,
            favorite: state.favorite != initial.favorite ? state.favorite : nil,
            collection: state.collection != initial.collection ? state.collection : nil,
            addedTags: state.tags.filter { !initial.tags.contains($0) },
            removedTags: initial.tags.filter { !state.tags.contains($0) })
    }

    private static func preset(_ input: SharedInput) -> ItemType {
        switch input {
        case .url(let url, _, _, _): ItemType.preset(for: URLCleaner.clean(url))
        case .text: .text
        case .file(_, let contentType, _): ItemType.preset(forContentType: contentType)
        }
    }

    /// `Share yyyy-MM-dd HH:mm`, Gregorian with ASCII digits whatever the device settings.
    private static func defaultCollectionName(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "Share \(formatter.string(from: date))"
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .lazy.compactMap { nonBlank(String($0)) }.first ?? ""
        return String(line.prefix(titleLength))
    }

    private static func stem(_ name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty ? name : stem
    }

    /// A safe, unique file name inside the request's inbox directory.
    private static func inboxName(for name: String, contentType: UTType, taken: inout Set<String>) -> String {
        let pathExtension = (name as NSString).pathExtension
        let ext = safe(pathExtension.isEmpty ? (contentType.preferredFilenameExtension ?? "") : pathExtension)
        var base = FileNamer.sanitize(stem(name))
        while base.contains("..") { base = base.replacingOccurrences(of: "..", with: ".") }
        let unique = FileNamer.uniqueName(base: base, ext: ext, existing: taken)
        taken.insert(unique)
        return unique
    }

    private static func safe(_ ext: String) -> String {
        String(ext.filter { $0.isLetter || $0.isNumber })
    }
}
