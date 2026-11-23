import SharesheetCore
import SwiftUI

/// One section per canonical URL; the user picks the copy to keep and the rest go to the Trash.
struct DuplicateGroupsView: View {
    @Environment(AppModel.self) private var model
    @State private var keepers: [String: ItemID] = [:]
    @State private var deleteFailure: Int?

    var body: some View {
        let groups = model.duplicateGroups()
        List {
            ForEach(groups) { group in
                Section {
                    ForEach(group.items) { item in
                        Button {
                            keepers[group.id] = item.id
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: keeper(for: group) == item.id
                                    ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(.tint)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    ItemRow(item: item, favicon: model.favicon(for: item))
                                    Text(verbatim: item.id.collection.relativePath)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityValue(Text(keeper(for: group) == item.id ? "Kept" : "Duplicate"))
                    }
                    Button("Trash \(extras(in: group).count) duplicates", role: .destructive) {
                        trashExtras(of: group)
                    }
                } header: {
                    Text(verbatim: group.key)
                }
            }
        }
        .navigationTitle("Duplicates")
        .overlay {
            if groups.isEmpty {
                ContentUnavailableView("No duplicates", systemImage: "doc.on.doc")
            }
        }
        .alert("Couldn’t delete some duplicates", isPresented: $deleteFailure.isPresent()) {
            Button("OK") { deleteFailure = nil }
        } message: {
            Text("\(deleteFailure ?? 0) copies are still there. Try again.")
        }
    }

    private func keeper(for group: DuplicateGroup) -> ItemID? {
        let chosen = keepers[group.id]
        return DuplicateFinder.keeper(
            in: group, chosen: chosen, currentID: chosen.map { model.current($0) })
    }

    private func extras(in group: DuplicateGroup) -> [ItemID] {
        guard let keeper = keeper(for: group) else { return [] }
        return group.items.map(\.id).filter { $0 != keeper }
    }

    private func trashExtras(of group: DuplicateGroup) {
        let extras = extras(in: group)
        guard !extras.isEmpty else { return }
        Task {
            let failed = await model.delete(extras)
            if failed.isEmpty {
                keepers[group.id] = nil
            } else {
                deleteFailure = failed.count
            }
        }
    }
}
