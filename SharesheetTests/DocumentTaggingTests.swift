import Foundation
import Testing
@testable import Sharesheet

struct DocumentTaggingTests {
    @Test func promptCutsTextAtTheLimit() {
        let text = String(repeating: "a", count: TagPrompt.maxTextCharacters) + "§" + String(repeating: "a", count: 20_000 - TagPrompt.maxTextCharacters - 1)
        #expect(text.count == 20_000)
        let prompt = TagPrompt.prompt(text: text)
        #expect(prompt.contains(String(text.prefix(6_000))))
        #expect(!prompt.contains("§"))
    }

    @Test func instructionsListExistingTagsAndAskForOneKind() {
        let instructions = TagPrompt.instructions(existingTags: ["Rechnung", "Kontoauszug"])
        #expect(instructions.contains("Rechnung"))
        #expect(instructions.contains("Kontoauszug"))
        #expect(instructions.contains("one"))
        #expect(instructions.contains("kind of document"))
        #expect(instructions.contains("existing tag"))
        #expect(instructions.contains("language of the document"))
    }
}
