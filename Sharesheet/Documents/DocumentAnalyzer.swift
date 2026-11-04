import Foundation
import SharesheetCore
import UniformTypeIdentifiers

enum TagMode: String, Sendable {
    case off, automatic, suggest
}

/// Reads the text of saved files and pages, stores keywords in the index and, depending on the mode, tags them.
/// One item at a time; nothing leaves the device.
actor DocumentAnalyzer {
    private let store: any ItemStore
    private let index: LibraryIndex
    private let tagger: any DocumentTagging
    private let tagMode: @Sendable () -> TagMode
    private var tail: Task<Void, Never>?

    init(
        store: any ItemStore, index: LibraryIndex, tagger: any DocumentTagging,
        tagMode: @escaping @Sendable () -> TagMode
    ) {
        self.store = store
        self.index = index
        self.tagger = tagger
        self.tagMode = tagMode
    }

    /// Analyzes every item that has no analysis yet. Returns how many were analyzed; items whose file is not on
    /// the device yet, and pages without archive text yet, are skipped and tried again next time. Stops between items when cancelled.
    func runPending() async -> Int {
        await serialized { await $0.analyzePending() }
    }

    /// One run at a time: actor methods interleave at every `await`. Cancelling the caller cancels its run.
    private func serialized<T: Sendable>(_ operation: @escaping @Sendable (DocumentAnalyzer) async -> T) async -> T {
        let previous = tail
        let task = Task { [self] in
            await previous?.value
            return await operation(self)
        }
        tail = Task { _ = await task.value }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func analyzePending() async -> Int {
        guard let candidates = try? index.analysisCandidates() else { return 0 }
        var analyzed = 0
        for candidate in candidates {
            if Task.isCancelled { break }
            if await analyze(candidate) { analyzed += 1 }
        }
        return analyzed
    }

    /// At most this many distinct terms of a document are looked up in the index.
    static let maxKeywordCandidates = 300

    /// The `limit` terms with the highest count; ties go to the alphabetically first term.
    static func topTerms(_ counts: [String: Int], limit: Int) -> [String: Int] {
        guard counts.count > limit else { return counts }
        let best = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(limit)
        return Dictionary(uniqueKeysWithValues: best.map { ($0.key, $0.value) })
    }

    /// True when `tags` already holds `tag`, or a spelling `TagCatalog` treats as the same tag.
    static func carries(_ tags: [String], _ tag: String) -> Bool {
        if tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) { return true }
        if let resolved = TagCatalog.resolve(tag, among: tags), tags.contains(resolved) { return true }
        return false
    }

    /// False when the item was skipped (file not available yet, item gone) and left without an analysis row.
    private func analyze(_ candidate: AnalysisCandidate) async -> Bool {
        let text: String
        if candidate.isFile {
            // Decide by extension before touching the store: asking for the file would start an iCloud
            // download, and only PDFs, images and text files are read.
            let type = UTType(filenameExtension: (candidate.source as NSString).pathExtension) ?? .data
            guard type.conforms(to: .pdf) || type.conforms(to: .image) || type.conforms(to: .plainText) else {
                try? index.setAnalysis(source: candidate.source, text: "", keywords: [], suggestedTag: nil)
                return true
            }
            let url: URL
            do {
                url = try await store.attachmentURL(candidate.source)
            } catch {
                return false  // downloading, not found or unreadable store: try again next run
            }
            text = await DocumentTextExtractor.text(from: url, contentType: type)
        } else {
            // The archive text arrives with the capture; until then leave no row so a later run retries.
            guard let archiveText = try? index.analysisText(forItem: candidate.id), !archiveText.isEmpty else { return false }
            text = archiveText
        }
        if Task.isCancelled { return false }

        // Keywords first: the document frequencies must count only the other documents.
        let counts = KeywordExtractor.termCounts(in: text)
        var keywords: [Keyword] = []
        if !counts.isEmpty {
            // One index query per term: only the most frequent terms of the document are candidates.
            let top = Self.topTerms(counts, limit: Self.maxKeywordCandidates)
            if let stats = try? index.documentFrequencies(of: Array(top.keys)) {
                keywords = KeywordExtractor.rank(counts: top, documents: stats.documents, frequencies: stats.frequencies)
            }
        }

        let mode = tagMode()
        var tag: String?
        if mode != .off, tagger.isAvailable, !text.isEmpty {
            let existing = (try? index.allTags()) ?? []
            if let answer = try? await tagger.tag(forText: text, existingTags: existing) {
                tag = TagCatalog.resolve(answer, among: existing)
            }
            if Task.isCancelled { return false }  // an interrupted model call is not an answer
        }

        var suggestion: String?
        if let tag {
            switch mode {
            case .automatic:
                if let updated = try? await store.modify(candidate.id, { item in
                    if !Self.carries(item.tags, tag) { item.tags.append(tag) }
                }) {
                    try? index.upsert(updated)
                }
            case .suggest:
                // No suggestion for a tag the item already carries.
                let current = (try? await store.item(candidate.id))?.tags ?? []
                if !current.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) { suggestion = tag }
            case .off:
                break
            }
        }

        try? index.setAnalysis(
            source: candidate.source, text: candidate.isFile ? text : nil, keywords: keywords, suggestedTag: suggestion)
        return true
    }
}
