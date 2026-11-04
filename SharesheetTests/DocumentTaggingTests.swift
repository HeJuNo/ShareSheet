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

    @Test func largeTagLibraryIsCappedToTheBudgetInOrderWithoutPartialNames() {
        let tags = (1...500).map { "Tag\($0)" }
        let listed = TagPrompt.listedTags(tags)
        #expect(listed.joined(separator: ", ").count <= TagPrompt.maxTagListCharacters)
        #expect(listed.count < tags.count)
        #expect(listed == Array(tags.prefix(listed.count)))
        let instructions = TagPrompt.instructions(existingTags: tags)
        #expect(instructions.contains("Existing tags: " + listed.joined(separator: ", ") + "."))
        #expect(!instructions.contains(tags[listed.count]))
    }

    @Test func smallTagListIsListedCompletelyAndEmptyNamesAreSkipped() {
        let instructions = TagPrompt.instructions(existingTags: ["Rechnung", "", "Vertrag"])
        #expect(instructions.contains("Existing tags: Rechnung, Vertrag."))
    }
}
