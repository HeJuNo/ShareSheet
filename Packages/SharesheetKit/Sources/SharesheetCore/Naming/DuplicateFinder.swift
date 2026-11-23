import Foundation

/// Items that point at the same page in different spellings of its URL.
public struct DuplicateGroup: Identifiable, Equatable, Sendable {
    public var key: String
    public var items: [IndexedItem]
    public var id: String { key }
}

public enum DuplicateFinder {
    /// Groups of two or more items with the same canonical URL, oldest first inside a group
    /// and groups sorted by their canonical URL.
    public static func groups(_ items: [IndexedItem]) -> [DuplicateGroup] {
        var byKey: [String: [IndexedItem]] = [:]
        for item in items {
            guard let url = item.url, let key = URLCleaner.canonical(url) else { continue }
            byKey[key, default: []].append(item)
        }
        return byKey
            .filter { $0.value.count > 1 }
            .map { key, items in
                DuplicateGroup(key: key, items: items.sorted {
                    $0.created == $1.created ? $0.id.relativePath < $1.id.relativePath : $0.created < $1.created
                })
            }
            .sorted { $0.key < $1.key }
    }

    /// How many copies would be removed if every group kept its oldest item.
    public static func extraCopyCount(_ items: [IndexedItem]) -> Int {
        groups(items).reduce(0) { $0 + $1.items.count - 1 }
    }

    /// The keeper for `group`: the chosen item after moves when it is still in the group, else the
    /// oldest. Guards against a stored choice whose item was moved or deleted meanwhile.
    public static func keeper(in group: DuplicateGroup, chosen: ItemID?, currentID: ItemID?) -> ItemID? {
        guard let chosen else { return group.items.first?.id }
        let resolved = currentID ?? chosen
        return group.items.contains { $0.id == resolved } ? resolved : group.items.first?.id
    }
}
