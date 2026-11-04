import Foundation
import Observation
import SharesheetCore

/// Why the rules file is not in use, for the settings; nil when it is fine or absent.
@MainActor @Observable
final class RulesStatus {
    var problem: String?
}

enum RulesLoading {
    /// The rules in `<root>/rules.json`; none when the library or the file is missing or the file is broken
    /// (then `status.problem` says why).
    static func load(root: URL?, status: RulesStatus) async -> RuleSet {
        guard let root else { return .empty }
        switch RuleFile.load(from: root) {
        case .none:
            await MainActor.run { status.problem = nil }
            return .empty
        case .rules(let set):
            await MainActor.run { status.problem = nil }
            return set
        case .invalid(let message):
            await MainActor.run { status.problem = message }
            return .empty
        }
    }
}
