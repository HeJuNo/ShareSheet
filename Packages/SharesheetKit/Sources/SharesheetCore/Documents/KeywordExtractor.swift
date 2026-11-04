import Foundation
import NaturalLanguage

/// Term counting and TF-IDF style ranking for document keywords. Pure and deterministic.
public enum KeywordExtractor {
    private static let minimumLength = 3

    /// Lowercased content words of `text` with their occurrence counts. Keeps nouns, proper nouns,
    /// adjectives and unclassified words of at least three characters (two when mixed with a digit, e.g. a1); drops stopwords and pure numbers.
    public static func termCounts(in text: String) -> [String: Int] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let language = recognizer.dominantLanguage

        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        if let language { tagger.setLanguage(language, range: text.startIndex..<text.endIndex) }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        if let language { tokenizer.setLanguage(language) }

        let kept: Set<NLTag> = [.noun, .adjective, .otherWord]
        var counts: [String: Int] = [:]
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let term = text[range].lowercased()
            let long = term.count >= minimumLength || (term.count >= 2 && term.contains(where: \.isNumber))
            guard long, term.contains(where: \.isLetter) else { return true }
            let (tag, _) = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lexicalClass)
            if let tag, !kept.contains(tag) { return true }
            counts[term, default: 0] += 1
            return true
        }
        return counts
    }

    /// `score = (1 + ln(tf)) * (ln((N + 1) / (df + 1)) + 1)`, highest first, ties by term ascending.
    public static func rank(counts: [String: Int], documents: Int, frequencies: [String: Int], limit: Int = 12) -> [Keyword] {
        guard limit > 0 else { return [] }
        let scored = counts.compactMap { term, tf -> Keyword? in
            guard tf > 0 else { return nil }
            let df = frequencies[term] ?? 0
            let idf = log(Double(documents + 1) / Double(df + 1)) + 1
            return Keyword(term: term, score: (1 + log(Double(tf))) * idf)
        }
        let sorted = scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.term < $1.term }
        return Array(sorted.prefix(limit))
    }
}
