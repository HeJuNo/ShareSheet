import Foundation
import SharesheetCore

/// Where items went when rules moved them, so a screen that still holds the old id keeps working.
final class MoveRedirects: @unchecked Sendable {
    private let lock = NSLock()
    private var targets: [ItemID: ItemID] = [:]

    func record(from old: ItemID, to new: ItemID) {
        lock.withLock { targets[old] = new }
    }

    /// The id the item has now; `id` itself when it never moved. Follows several moves, ends at a loop.
    func current(_ id: ItemID) -> ItemID {
        lock.withLock {
            var current = id
            var seen: Set<ItemID> = [id]
            while let next = targets[current], seen.insert(next).inserted { current = next }
            return current
        }
    }
}
