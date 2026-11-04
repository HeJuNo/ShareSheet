import Foundation
import SharesheetCore
@testable import Sharesheet

/// Records which items the rules were applied to; `probe` reads state at that moment (e.g. the stored text).
final class RecordingRules: RuleApplying, @unchecked Sendable {
    private let lock = NSLock()
    private var _applied: [ItemID] = []
    private var _probes: [String?] = []
    private let probe: (@Sendable (ItemID) -> String?)?

    init(probe: (@Sendable (ItemID) -> String?)? = nil) { self.probe = probe }

    var applied: [ItemID] { lock.withLock { _applied } }
    var probes: [String?] { lock.withLock { _probes } }

    func apply(to id: ItemID) async {
        let value = probe?(id)
        lock.withLock {
            _applied.append(id)
            _probes.append(value)
        }
    }
}
