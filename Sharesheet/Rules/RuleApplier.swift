import Foundation
import OSLog
import SharesheetCore

/// What the rules would change for one item: tags it does not carry yet, and the collection to move it to.
struct RulePlan: Equatable, Sendable {
    var tags: [String]
    var moveTo: CollectionPath?
    /// A new `created` read from the text; never set for an item whose date was set by hand.
    var date: Date? = nil
    /// Fields whose value is new or different, by name.
    var fields: [String: FieldValue] = [:]
    /// A new title from a template; never set for an item whose title was edited by hand.
    var title: String? = nil

    var isEmpty: Bool { tags.isEmpty && moveTo == nil && date == nil && fields.isEmpty && title == nil }
}

struct RulePreview: Equatable, Sendable {
    var items: Int
    var tagsAdded: Int
    var moved: Int
    var dates = 0
    var fields = 0
    var titles = 0
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
            if let tag = TagCatalog.resolve(name, among: existing), !TagCatalog.carries(item.tags + tags, tag) {
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
        // Fields set or deleted by hand are left alone; they still count as inputs of formulas.
        let protected = item.fieldsManual.union(item.fieldsDeleted)
        // First pattern with a readable value wins per field name; equal values are not changes.
        var read: [String: FieldValue] = [:]
        for definition in outcome.fieldDefinitions where read[definition.name] == nil && !protected.contains(definition.name) {
            guard let pattern = definition.pattern, var value = FieldExtractor.value(in: text, pattern: pattern) else { continue }
            if let op = definition.op, let operand = definition.operand, case .number(let number) = value {
                guard let result = op.apply(number, operand), result.isFinite else { continue }
                value = .number(result)
            }
            read[definition.name] = value
        }
        Self.calculate(outcome.fieldDefinitions, protected: protected, existing: item.fields, into: &read)
        let fields = read.filter { !Self.same($0.value, item.fields[$0.key]) }
        var title: String?
        if !item.titleManual {
            let known = item.fields.merging(read) { _, new in new }
            title = outcome.titleTemplates.lazy.compactMap { TitleTemplate.fill($0, fields: known) }.first
            if title == item.title { title = nil }
        }
        let plan = RulePlan(tags: tags, moveTo: move, date: date, fields: fields, title: title)
        return plan.isEmpty ? nil : plan
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
            preview.fields += plan.fields.count
            if plan.title != nil { preview.titles += 1 }
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
            if !plan.tags.isEmpty || plan.date != nil || !plan.fields.isEmpty || plan.title != nil {
                let (tags, date, fields, title) = (plan.tags, plan.date, plan.fields, plan.title)
                let saved = try await store.modify(current) { item in
                    for tag in tags where !TagCatalog.carries(item.tags, tag) { item.tags.append(tag) }
                    if let date, !item.createdManual { item.created = date }
                    for (name, value) in fields where !item.fieldsManual.contains(name) && !item.fieldsDeleted.contains(name) {
                        item.fields[name] = value
                    }
                    if let title, !item.titleManual { item.title = title }
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

    /// Evaluates formula fields into `fields`. A formula runs once every field it names that is itself calculated by a
    /// formula has been calculated in this run, so no stored result is used stale; circular or incomplete formulas never
    /// run and leave their field as it was.
    private static func calculate(
        _ definitions: [FieldDefinition], protected: Set<String>, existing: [String: FieldValue],
        into fields: inout [String: FieldValue]
    ) {
        var pending: [String: String] = [:]  // name -> formula, first definition wins
        for definition in definitions {
            guard let formula = definition.formula, !protected.contains(definition.name), fields[definition.name] == nil,
                pending[definition.name] == nil
            else { continue }
            pending[definition.name] = formula
        }
        var settled = Set<String>()  // calculated, or given up on
        var progressed = true
        while progressed {
            progressed = false
            for (name, formula) in pending where !settled.contains(name) {
                guard let references = FormulaEvaluator.references(in: formula),
                    references.allSatisfy({ pending[$0] == nil || settled.contains($0) })
                else { continue }
                settled.insert(name)
                progressed = true
                var numbers: [String: Double] = [:]
                for (key, value) in existing.merging(fields, uniquingKeysWith: { _, new in new }) {
                    if case .number(let number) = value { numbers[key] = number }
                }
                for reference in references where pending[reference] != nil && fields[reference] == nil {
                    numbers[reference] = nil  // given up on: not usable, even if an older result is stored
                }
                if let value = FormulaEvaluator.evaluate(formula, fields: numbers) { fields[name] = .number(value) }
            }
        }
    }

    /// Equal values, with dates compared to the second.
    private static func same(_ a: FieldValue, _ b: FieldValue?) -> Bool {
        if case .date(let x) = a, case .date(let y)? = b { return abs(x.timeIntervalSince(y)) < 1 }
        return a == b
    }

    /// The collection `name` ("Parent/Child") names: an existing one regardless of case, else a new path.
    /// Nil for empty parts, reserved or hidden folder names.
    private func collection(named name: String) async -> CollectionPath? {
        // Checked before sanitizing: it would turn "", ".." and ".hidden" into valid names.
        let raw = name.split(separator: "/", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard raw.allSatisfy({ !$0.isEmpty && LibraryLayout.isCollectionName($0) }) else { return nil }
        let path = CollectionPath(components: raw.map { FileNamer.sanitize($0) })
        let known = (try? await store.collections()) ?? []
        return known.first { $0.relativePath.caseInsensitiveCompare(path.relativePath) == .orderedSame } ?? path
    }
}
