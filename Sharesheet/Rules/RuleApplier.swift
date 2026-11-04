import Foundation
import OSLog
import SharesheetCore

protocol RuleApplying: Sendable {
    /// Applies the rules to one item. Never throws: a failing rule run must not hold up capture or analysis.
    func apply(to id: ItemID) async
}

/// Evaluates the rules for an item and writes the result: tags are only added, and only items still in
/// `Unsorted` are moved. Running it again changes nothing.
actor RuleApplier: RuleApplying {
    typealias Evaluate = @Sendable (RuleSet, Item, String) async throws -> RuleOutcome

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Sharesheet", category: "Rules")

    private let store: any ItemStore
    private let index: LibraryIndex
    private let redirects: MoveRedirects?
    private let rules: @Sendable () async -> RuleSet
    private let evaluate: Evaluate

    init(
        store: any ItemStore, index: LibraryIndex, redirects: MoveRedirects? = nil,
        rules: @escaping @Sendable () async -> RuleSet, evaluate: @escaping Evaluate
    ) {
        self.store = store
        self.index = index
        self.redirects = redirects
        self.rules = rules
        self.evaluate = evaluate
    }

    func apply(to id: ItemID) async {
        let set = await rules()
        guard !set.rules.isEmpty, let item = try? await store.item(id) else { return }
        let text = (try? index.analysisText(forItem: id)) ?? ""
        let outcome: RuleOutcome
        do {
            outcome = try await evaluate(set, item, text)
        } catch {
            Self.log.error("Evaluating the rules failed: \(error)")
            return
        }

        var current = id
        let existing = (try? index.allTags()) ?? []
        let tags = outcome.tags.compactMap { TagCatalog.resolve($0, among: existing) }
        do {
            if !tags.isEmpty {
                let saved = try await store.modify(current) { item in
                    for tag in tags where !DocumentAnalyzer.carries(item.tags, tag) { item.tags.append(tag) }
                }
                try? index.upsert(saved)
            }
            if let target = outcome.moveTo, current.collection == .unsorted, let path = await collection(named: target),
                path != .unsorted
            {
                let moved = try await store.move(current, to: path)
                try? index.remove(current)
                try? index.upsert(moved)
                redirects?.record(from: current, to: moved.id)
                current = moved.id
            }
        } catch {
            // Most often the item was deleted while the rules ran.
            Self.log.error("Applying the rules failed: \(error)")
        }
    }

    /// The collection `name` ("Parent/Child") names: an existing one regardless of case, else a new path.
    /// Nil for empty parts, reserved or hidden folder names.
    private func collection(named name: String) async -> CollectionPath? {
        // Checked before sanitizing: it would turn "", ".." and ".hidden" into valid names.
        let raw = name.split(separator: "/", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard raw.allSatisfy({ !$0.isEmpty && $0 != "_attachments" && !$0.hasPrefix(".") }) else { return nil }
        let path = CollectionPath(components: raw.map { FileNamer.sanitize($0) })
        let known = (try? await store.collections()) ?? []
        return known.first { $0.relativePath.caseInsensitiveCompare(path.relativePath) == .orderedSame } ?? path
    }
}
