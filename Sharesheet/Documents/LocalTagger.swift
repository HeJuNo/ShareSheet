import Foundation
import SharesheetCore

/// Tags a document without Apple Intelligence: first by similarity to the user's already tagged documents
/// (TF-IDF cosine over the same terms the keywords use), then by a tag name found in the text, then by typical
/// words of a few common kinds. Needs no model download and runs on every device; nothing leaves the iPhone.
struct LocalTagger: DocumentTagging {
    typealias Example = (tag: String, text: String)

    /// Cosine similarity from which a tagged document counts as similar. shortcut: one fixed value for all languages, retune with real documents.
    static let minSimilarity = 0.35
    static let maxExamples = 300
    static let analyzedCharacters = 6_000
    static let minimumTagNameLength = 4

    /// Typical words per kind, lowercased. Only used when nothing in the library matches.
    static let triggers: [(tag: String, words: [String])] = [
        ("Rechnung", ["rechnungsnummer", "rechnungsbetrag", "rechnung nr", "invoice"]),
        ("Kontoauszug", ["kontoauszug", "kontostand", "buchungstag", "account statement"]),
        ("Mahnung", ["mahnung", "zahlungserinnerung", "mahngebühr"]),
        ("Gutschrift", ["gutschriftsanzeige", "credit note"]),
        ("Vertrag", ["vertragsnummer", "vertragspartner", "kündigungsfrist"]),
        ("Kündigung", ["kündigung", "hiermit kündige"]),
        ("Angebot", ["angebotsnummer", "angebot nr"]),
        ("Lieferschein", ["lieferschein"]),
        ("Quittung", ["quittung", "kassenbon"]),
        ("Bescheid", ["bescheid"]),
        ("Versicherungsschein", ["versicherungsschein", "versicherungsnummer"]),
        ("Lohnabrechnung", ["lohnabrechnung", "gehaltsabrechnung", "entgeltabrechnung"]),
    ]

    let examples: @Sendable () -> [Example]
    private let counts = CountCache()

    init(examples: @escaping @Sendable () -> [Example]) { self.examples = examples }

    var isAvailable: Bool { true }

    func tag(forText text: String, existingTags: [String]) async throws -> String? {
        if let tag = similarTag(to: text) { return tag }
        if let tag = Self.mostMentioned(existingTags, in: text) { return tag }
        return Self.mostMentioned(Self.triggers.map(\.tag), words: Self.triggers.map(\.words), in: text)
    }

    private func similarTag(to text: String) -> String? {
        let examples = Array(examples().prefix(Self.maxExamples))
        guard !examples.isEmpty else { return nil }
        let exampleCounts = examples.map { counts.counts(for: $0.text) }
        let query = counts.counts(for: text)
        // Inverse document frequency over the examples: terms every document has say little about its kind.
        var frequency: [String: Int] = [:]
        for terms in exampleCounts { for term in terms.keys { frequency[term, default: 0] += 1 } }
        let total = Double(examples.count)
        func weights(_ terms: [String: Int]) -> [String: Double] {
            terms.reduce(into: [:]) { $0[$1.key] = (1 + log(Double($1.value))) * log(1 + total / Double(frequency[$1.key] ?? 1)) }
        }
        let queryWeights = weights(query)
        var best: (tag: String, similarity: Double)?
        for (example, terms) in zip(examples, exampleCounts) {
            let similarity = Self.cosine(queryWeights, weights(terms))
            if similarity > (best?.similarity ?? 0) { best = (example.tag, similarity) }
        }
        guard let best, best.similarity >= Self.minSimilarity else { return nil }
        return best.tag
    }

    /// The tag whose name occurs most often in `text`; the earlier tag wins a tie. Nil when none occurs.
    static func mostMentioned(_ tags: [String], in text: String) -> String? {
        let usable = tags.filter { $0.count >= minimumTagNameLength }
        return mostMentioned(usable, words: usable.map { [$0.lowercased()] }, in: text)
    }

    private static func mostMentioned(_ tags: [String], words: [[String]], in text: String) -> String? {
        let haystack = text.lowercased()
        var best: (tag: String, count: Int)?
        for (tag, words) in zip(tags, words) {
            let count = words.reduce(0) { $0 + haystack.components(separatedBy: $1).count - 1 }
            if count > (best?.count ?? 0) { best = (tag, count) }
        }
        return best?.tag
    }

    static func cosine(_ a: [String: Double], _ b: [String: Double]) -> Double {
        let (small, large) = a.count <= b.count ? (a, b) : (b, a)
        var dot = 0.0
        for (term, weight) in small { dot += weight * (large[term] ?? 0) }
        let norm = a.values.reduce(0) { $0 + $1 * $1 }.squareRoot() * b.values.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? dot / norm : 0
    }
}

/// Term counts per document start; the library's examples are the same on every run.
private final class CountCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: [String: Int]] = [:]

    func counts(for text: String) -> [String: Int] {
        let start = String(text.prefix(LocalTagger.analyzedCharacters))
        if let cached = lock.withLock({ cache[start] }) { return cached }
        let counts = KeywordExtractor.termCounts(in: start)
        lock.withLock { cache[start] = counts }
        return counts
    }
}

/// Uses the Apple Intelligence tagger when it can answer, otherwise the local one.
struct FallbackTagger: DocumentTagging {
    let primary: any DocumentTagging
    let fallback: any DocumentTagging

    var isAvailable: Bool { primary.isAvailable || fallback.isAvailable }

    func tag(forText text: String, existingTags: [String]) async throws -> String? {
        if primary.isAvailable, let answer = try? await primary.tag(forText: text, existingTags: existingTags) { return answer }
        return try await fallback.tag(forText: text, existingTags: existingTags)
    }
}
