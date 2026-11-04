import Foundation
import Testing
@testable import SharesheetCore

@Suite struct KeywordExtractorTests {
    @Test func termCountsLowercaseAndDropNoise() {
        let counts = KeywordExtractor.termCounts(in: "Die Rechnung A1 Telekom. Rechnung für 39,90 € und die 2026")
        #expect(counts["rechnung"] == 2)
        #expect(counts["telekom"] == 1)
        #expect(counts["a1"] != nil)
        for noise in ["die", "und", "für", "2026", "39,90", "39", "90"] {
            #expect(counts[noise] == nil, "\(noise) should be dropped")
        }
    }

    @Test func rarerTermsScoreHigherThanCommonOnes() {
        let keywords = KeywordExtractor.rank(
            counts: ["telekom": 3, "rechnung": 3], documents: 100,
            frequencies: ["telekom": 2, "rechnung": 80])
        #expect(keywords.first?.term == "telekom")
    }

    @Test func moreFrequentTermsScoreHigherWhenRarityIsEqual() {
        let keywords = KeywordExtractor.rank(
            counts: ["alpha": 5, "beta": 1], documents: 10, frequencies: ["alpha": 3, "beta": 3])
        #expect(keywords.map(\.term) == ["alpha", "beta"])
    }

    @Test func limitAndOrderAreRespected() {
        let counts = ["delta": 1, "alpha": 1, "charlie": 1, "bravo": 1, "echo": 4]
        let keywords = KeywordExtractor.rank(counts: counts, documents: 0, frequencies: [:], limit: 3)
        #expect(keywords.map(\.term) == ["echo", "alpha", "bravo"])
        #expect(keywords.count == 3)
        #expect(zip(keywords, keywords.dropFirst()).allSatisfy { $0.score >= $1.score })
    }

    @Test func scoreFormulaIsPinned() {
        let keywords = KeywordExtractor.rank(counts: ["telekom": 3], documents: 100, frequencies: ["telekom": 2])
        let expected = (1 + log(3.0)) * (log(101.0 / 3.0) + 1)
        #expect(abs(keywords[0].score - expected) < 1e-9)
    }

    @Test func emptyTextGivesNoKeywords() {
        #expect(KeywordExtractor.termCounts(in: "").isEmpty)
        #expect(KeywordExtractor.termCounts(in: "  \n ").isEmpty)
        #expect(KeywordExtractor.rank(counts: [:], documents: 5, frequencies: [:]).isEmpty)
    }

    @Test func functionWordOnlySentencesYieldNoTerms() {
        let de = "Der die das und oder aber nicht auch wenn dass wie bei aus von zum zur über unter nach für mit dem den des einem einer eines sind ist war wird werden hat haben"
        let en = "The and or but not also if that how with from into over under after for the of is are was were will have has been"
        for useTagger in [true, false] {
            #expect(KeywordExtractor.termCounts(in: de, useTagger: useTagger).isEmpty)
            #expect(KeywordExtractor.termCounts(in: en, useTagger: useTagger).isEmpty)
        }
    }

    private static let invoiceBlock = "Die Mobilfunkleistungen umfassen Gespräche, Nachrichten und Datenübertragung im österreichischen Netz. Das Datenvolumen wird monatlich neu bereitgestellt und verfällt nicht. Gesprächsentgelte außerhalb des Tarifs werden nach Sekunden abgerechnet. Die Telekom behält sich Preisanpassungen nach Maßgabe der Vertragsbedingungen vor. Beanstandungen der Rechnung sind innerhalb von drei Monaten schriftlich bekanntzugeben. Für Rückfragen steht der Kundendienst werktags zur Verfügung. "

    private func assertInvoiceKeywords(useTagger: Bool) {
        let text = String(repeating: Self.invoiceBlock, count: 20)
        let counts = KeywordExtractor.termCounts(in: text, useTagger: useTagger)
        let top = KeywordExtractor.rank(counts: counts, documents: 0, frequencies: [:], limit: 8).map(\.term)
        for stop in ["der", "die", "das", "und", "nach", "für", "im", "des", "von", "sind", "werden"] {
            #expect(!top.contains(stop), "\(stop) leaked into \(top)")
        }
        #expect(counts["rechnung"] != nil)
        #expect(counts["datenvolumen"] != nil)
    }

    @Test func longGermanInvoiceKeywordsContainNoStopwords() {
        assertInvoiceKeywords(useTagger: true)
        assertInvoiceKeywords(useTagger: false)
    }

    @Test func stopwordsAreDroppedWithoutTagger() {
        let counts = KeywordExtractor.termCounts(in: "Die Rechnung und der Telekom Vertrag für die Rechnung", useTagger: false)
        #expect(counts["rechnung"] == 2)
        #expect(counts["die"] == nil && counts["und"] == nil && counts["der"] == nil && counts["für"] == nil)
    }
}
