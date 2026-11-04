import Foundation
import FoundationModels

/// Proposes a tag (the kind of document) for a document's text.
protocol DocumentTagging: Sendable {
    var isAvailable: Bool { get }
    /// Returns nil when no on-device model can answer.
    func tag(forText text: String, existingTags: [String]) async throws -> String?
}

enum TagPrompt {
    static let maxTextCharacters = 6_000
    /// Budget for the joined list of existing tags; the on-device model has a small context window.
    static let maxTagListCharacters = 600

    /// Keeps the first tags (most used first) while the joined list fits the budget; never cuts a name.
    static func listedTags(_ existingTags: [String]) -> [String] {
        var listed: [String] = []
        var length = 0
        for name in existingTags {
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { continue }
            let added = name.count + (listed.isEmpty ? 0 : 2)
            if length + added > maxTagListCharacters { break }
            listed.append(name)
            length += added
        }
        return listed
    }

    static func instructions(existingTags: [String]) -> String {
        var text = """
        You classify documents. Name the one kind of document the text is, for example Rechnung, Gutschrift, Kontoauszug or Beitragsvorschreibung. \
        Answer with a short tag of one or two words, written in the language of the document.
        """
        let listed = listedTags(existingTags)
        if !listed.isEmpty {
            text += "\nExisting tags: " + listed.joined(separator: ", ") + "."
            text += "\nIf one existing tag fits the document, prefer that existing tag exactly as written. Otherwise propose a new tag."
        }
        return text
    }

    static func prompt(text: String) -> String {
        "Document text:\n" + String(text.prefix(maxTextCharacters))
    }
}

@Generable
struct DocumentKind {
    @Guide(description: "One or two words naming the kind of document, in the language of the document")
    var tag: String
}

struct FoundationModelsTagger: DocumentTagging {
    var isAvailable: Bool { SystemLanguageModel.default.availability == .available }

    func tag(forText text: String, existingTags: [String]) async throws -> String? {
        guard isAvailable else { return nil }
        let session = LanguageModelSession(instructions: TagPrompt.instructions(existingTags: existingTags))
        let kind = try await session.respond(to: TagPrompt.prompt(text: text), generating: DocumentKind.self)
        return kind.content.tag
    }
}
