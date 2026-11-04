import Foundation
import Testing
@testable import Sharesheet

struct LocalTaggerTests {
    private let invoice = "Rechnung Nr. 2024-117. Rechnungsbetrag 118,50 EUR inklusive 19 Prozent Umsatzsteuer. Bitte überweisen Sie den Betrag innerhalb von 14 Tagen auf unser Konto."
    private let statement = "Kontoauszug Oktober. Alter Kontostand 1.204,33 EUR. Buchungstag Wert Verwendungszweck Lastschrift Gutschrift. Neuer Kontostand 987,10 EUR."

    private func tagger(_ examples: [(tag: String, text: String)] = []) -> LocalTagger {
        LocalTagger(examples: { examples })
    }

    @Test func isAlwaysAvailable() {
        #expect(tagger().isAvailable)
    }

    @Test func existingTagNameInTheTextWins() async throws {
        let answer = try await tagger().tag(forText: "Vertrag über die Lieferung von Strom", existingTags: ["Rechnung", "Vertrag"])
        #expect(answer == "Vertrag")
    }

    @Test func mostFrequentTagNameWins() async throws {
        let text = "Mahnung zur Rechnung 4711. Die Rechnung ist offen. Zahlen Sie die Rechnung. Der Vertrag bleibt bestehen."
        let answer = try await tagger().tag(forText: text, existingTags: ["Vertrag", "Rechnung"])
        #expect(answer == "Rechnung")
    }

    @Test func triggerWordProposesAKindWithoutExistingTags() async throws {
        let answer = try await tagger().tag(forText: statement, existingTags: [])
        #expect(answer == "Kontoauszug")
    }

    @Test func unknownTextGivesNoAnswer() async throws {
        let answer = try await tagger().tag(forText: "Ein Spaziergang durch den Wald im Herbst.", existingTags: ["Rechnung"])
        #expect(answer == nil)
    }

    @Test func similarTaggedDocumentDecidesTheTag() async throws {
        // The tag names do not occur in the text: only the similarity can find "Beleg".
        let examples = [(tag: "Bank", text: statement), (tag: "Beleg", text: invoice)]
        let other = "Rechnung Nr. 2025-003. Rechnungsbetrag 64,00 EUR zuzüglich Umsatzsteuer. Zahlbar binnen 14 Tagen."
        let answer = try await tagger(examples).tag(forText: other, existingTags: ["Bank", "Beleg"])
        #expect(answer == "Beleg")
    }

    @Test func similarityBeatsAMentionedTagName() async throws {
        let examples = [(tag: "Mahnung", text: "Zahlungserinnerung. Trotz Fälligkeit konnten wir keinen Zahlungseingang feststellen. Bitte begleichen Sie den offenen Betrag umgehend, sonst folgen Mahngebühren."),
                        (tag: "Rechnung", text: invoice)]
        let text = "Zahlungserinnerung. Wir konnten keinen Zahlungseingang zu Rechnung 12 feststellen. Bitte begleichen Sie den offenen Betrag umgehend, sonst folgen Mahngebühren."
        let answer = try await tagger(examples).tag(forText: text, existingTags: ["Rechnung", "Mahnung"])
        #expect(answer == "Mahnung")
    }

    @Test func fallbackUsesTheFallbackOnlyWhenThePrimaryIsUnavailableOrSilent() async throws {
        struct Stub: DocumentTagging {
            var available: Bool
            var answer: String?
            var isAvailable: Bool { available }
            func tag(forText text: String, existingTags: [String]) async throws -> String? { answer }
        }
        let both = FallbackTagger(primary: Stub(available: true, answer: "A"), fallback: Stub(available: true, answer: "B"))
        #expect(try await both.tag(forText: "x", existingTags: []) == "A")
        let silent = FallbackTagger(primary: Stub(available: true, answer: nil), fallback: Stub(available: true, answer: "B"))
        #expect(try await silent.tag(forText: "x", existingTags: []) == "B")
        let off = FallbackTagger(primary: Stub(available: false, answer: "A"), fallback: Stub(available: true, answer: "B"))
        #expect(try await off.tag(forText: "x", existingTags: []) == "B")
        #expect(off.isAvailable)
    }
}
