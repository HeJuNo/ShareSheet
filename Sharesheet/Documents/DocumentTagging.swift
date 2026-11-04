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

    static func instructions(existingTags: [String]) -> String {
        var text = """
        You classify documents. Name the one kind of document the text is, for example Rechnung, Gutschrift, Kontoauszug or Beitragsvorschreibung. \
        Answer with a short tag of one or two words, written in the language of the document.
        """
        if !existingTags.isEmpty {
            text += "\nExisting tags: " + existingTags.joined(separator: ", ") + "."
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
