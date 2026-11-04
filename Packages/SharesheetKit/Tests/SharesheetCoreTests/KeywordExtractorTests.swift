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
}
