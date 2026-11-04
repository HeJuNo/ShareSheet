import Foundation
import SharesheetCore
import ZenUniffi

/// Evaluates rule sets with the ZEN engine. The engine is created once; a compiled decision is kept until the
/// rules change.
actor RuleEngine {
    private let engine: ZenEngine
    private var decisions: [Data: ZenDecision] = [:]

    init() throws {
        engine = try ZenEngine(loader: nil, customNode: nil)
    }

    /// An empty outcome when no rule in `set` is usable.
    func outcome(for set: RuleSet, item: Item, text: String) async throws -> RuleOutcome {
        guard let compiled = RuleCompiler.compile(set) else { return RuleOutcome(tags: [], moveTo: nil) }
        let decision: ZenDecision
        if let cached = decisions[compiled.decision] {
            decision = cached
        } else {
            decision = try engine.createDecision(content: compiled.decision)
            if decisions.count >= 4 { decisions.removeAll() }  // rules change rarely; keep the cache small
            decisions[compiled.decision] = decision
        }
        let context = RuleContext.json(for: item, text: text, values: compiled.values)
        let response = try await decision.evaluate(context: context, options: nil)
        return RuleCompiler.outcome(fromResult: response.result)
    }
}
