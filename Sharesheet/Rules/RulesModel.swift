import Foundation
import Observation
import SharesheetCore

enum RulesModelError: Error { case notWritable }

/// The rules as the editor sees them. A rules file that cannot be read blocks saving, so a hand-written file is
/// never overwritten by accident.
@MainActor @Observable
final class RulesModel {
    enum State: Equatable {
        case loading
        case ready
        /// The file exists but cannot be read; the message says why.
        case blocked(String)
        /// No library (iCloud off).
        case unavailable
    }

    private(set) var state: State = .loading
    private(set) var rules: [Rule] = []

    @ObservationIgnored private let root: () async -> URL?
    @ObservationIgnored private let applier: RuleApplier?
    @ObservationIgnored private let itemIDs: () -> [ItemID]

    init(root: @escaping () async -> URL?, applier: RuleApplier?, itemIDs: @escaping () -> [ItemID]) {
        self.root = root
        self.applier = applier
        self.itemIDs = itemIDs
    }

    func reload() async {
        guard let root = await root() else {
            rules = []
            state = .unavailable
            return
        }
        switch RuleFile.load(from: root) {
        case .none:
            rules = []
            state = .ready
        case .rules(let set):
            rules = set.rules
            state = .ready
        case .invalid(let message):
            rules = []
            state = .blocked(message)
        }
    }

    func save(_ new: [Rule]) async throws {
        guard state == .ready, let root = await root() else { throw RulesModelError.notWritable }
        try RuleFile.save(RuleSet(rules: new), to: root)
        rules = new
    }

    /// Keeps a copy of the unreadable file as `rules.json.broken`, then starts an empty rules file.
    func startNewFile() async throws {
        guard case .blocked = state, let root = await root() else { throw RulesModelError.notWritable }
        try RuleFile.backUpBroken(in: root)
        try RuleFile.save(.empty, to: root)
        rules = []
        state = .ready
    }

    func preview() async -> RulePreview? {
        guard let applier else { return nil }
        return await applier.preview(ids: itemIDs())
    }

    func applyAll(progress: @escaping @Sendable (Int) -> Void) async -> Int {
        guard let applier else { return 0 }
        return await applier.applyAll(ids: itemIDs(), progress: progress)
    }

    var itemCount: Int { itemIDs().count }
}
