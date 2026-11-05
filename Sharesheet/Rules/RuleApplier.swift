import Foundation
import OSLog
import SharesheetCore

/// What the rules would change for one item: tags it does not carry yet, and the collection to move it to.
struct RulePlan: Equatable, Sendable {
    var tags: [String]
    var moveTo: CollectionPath?
    /// A new `created` read from the text; never set for an item whose date was set by hand.
    var date: Date? = nil
}

struct RulePreview: Equatable, Sendable {
    var items: Int
    var tagsAdded: Int
    var moved: Int
    var dates = 0
}

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
        guard let plan = await plan(for: id) else { return }
        await write(plan, to: id)
    }

    /// What the rules would change for this item, without changing it. Nil when nothing would change, there are
    /// no rules, the item is gone, or the evaluation failed.
    func plan(for id: ItemID) async -> RulePlan? {
        let set = await rules()
        guard !set.rules.isEmpty, let item = try? await store.item(id) else { return nil }
        let text = (try? index.analysisText(forItem: id)) ?? ""
        let outcome: RuleOutcome
        do {
            outcome = try await evaluate(set, item, text)
        } catch {
            Self.log.error("Evaluating the rules failed: \(error)")
            return nil
        }
        let existing = (try? index.allTags()) ?? []
        var tags: [String] = []
        for name in outcome.tags {
            if let tag = TagCatalog.resolve(name, among: existing), !DocumentAnalyzer.carries(item.tags + tags, tag) {
                tags.append(tag)
            }
        }
        var move: CollectionPath?
        if let target = outcome.moveTo, id.collection == .unsorted, let path = await collection(named: target),
            path != .unsorted
        {
            move = path
        }
        var date: Date?
        if !item.createdManual {
            date = outcome.datePatterns.lazy.compactMap { DateExtractor.date(in: text, pattern: $0) }.first
            if let found = date, abs(found.timeIntervalSince(item.created)) < 1 { date = nil }  // already that date
        }
        return tags.isEmpty && move == nil && date == nil ? nil : RulePlan(tags: tags, moveTo: move, date: date)
    }

    /// Counts what `applyAll` would change for `ids`; writes nothing.
    func preview(ids: [ItemID]) async -> RulePreview {
        var preview = RulePreview(items: 0, tagsAdded: 0, moved: 0)
        for id in ids {
            if Task.isCancelled { break }
            guard let plan = await plan(for: id) else { continue }
            preview.items += 1
            preview.tagsAdded += plan.tags.count
            if plan.moveTo != nil { preview.moved += 1 }
            if plan.date != nil { preview.dates += 1 }
        }
        return preview
    }

    /// Applies the rules to `ids`; returns how many items changed. `progress` gets the number of items done.
    func applyAll(ids: [ItemID], progress: @Sendable (Int) -> Void) async -> Int {
        var changed = 0
        for (done, id) in ids.enumerated() {
            if Task.isCancelled { break }
            if let plan = await plan(for: id) {
                await write(plan, to: id)
                changed += 1
            }
            progress(done + 1)
        }
        return changed
    }

    private func write(_ plan: RulePlan, to id: ItemID) async {
        var current = id
        do {
            if !plan.tags.isEmpty || plan.date != nil {
                let (tags, date) = (plan.tags, plan.date)
                let saved = try await store.modify(current) { item in
                    for tag in tags where !DocumentAnalyzer.carries(item.tags, tag) { item.tags.append(tag) }
                    if let date, !item.createdManual { item.created = date }
                }
                try? index.upsert(saved)
            }
            if let path = plan.moveTo {
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
