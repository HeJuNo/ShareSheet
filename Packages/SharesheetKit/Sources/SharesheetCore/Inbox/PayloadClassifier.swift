import Foundation
import UniformTypeIdentifiers

/// Decides how the share extension reads an attachment, from its registered types alone.
public enum PayloadClassifier {
    public enum Kind: Equatable, Sendable {
        /// Safari's preprocessing result; handled separately, never an item of its own.
        case skip
        case fileURL, url
        /// A short in-memory snippet.
        case text
        /// Copied by URL, never loaded into memory.
        case file
    }

    /// Loaded text above this many UTF-8 bytes is saved as a file instead.
    public static let maxTextBytes = 1_000_000

    private static let genericText: Set<String> = [
        UTType.plainText.identifier, UTType.utf8PlainText.identifier, UTType.utf16PlainText.identifier,
        UTType.utf16ExternalPlainText.identifier, UTType.text.identifier,
    ]

    public static func kind(registeredTypes: [String], suggestedName: String?) -> Kind {
        let types = registeredTypes.compactMap { UTType($0) }
        if types.contains(where: { $0.conforms(to: .propertyList) }) { return .skip }
        if types.contains(where: { $0.conforms(to: .fileURL) }) { return .fileURL }
        if types.contains(where: { $0.conforms(to: .url) }) { return .url }
        let textTypes = types.filter { $0.conforms(to: .text) }
        let isSnippet = !textTypes.isEmpty
            && textTypes.allSatisfy { genericText.contains($0.identifier) }
            && (suggestedName.map { ($0 as NSString).pathExtension.isEmpty } ?? true)
        return isSnippet ? .text : .file
    }

    public static func isTooLargeForText(_ text: String) -> Bool {
        text.utf8.count > maxTextBytes
    }
}
