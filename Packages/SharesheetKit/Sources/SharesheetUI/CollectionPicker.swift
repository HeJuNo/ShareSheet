import SharesheetCore
import SwiftUI

/// A row showing the selected collection; tapping it opens the collection tree to choose from.
/// With `onCreate`, the list offers "New collection…", created at the top level.
public struct CollectionPicker: View {
    @Binding private var selection: CollectionPath
    private let collections: [CollectionPath]
    private let onCreate: ((String, CollectionPath) async -> CollectionPath?)?
    @State private var showsList = false

    public init(
        selection: Binding<CollectionPath>, collections: [CollectionPath],
        onCreate: ((String, CollectionPath) async -> CollectionPath?)?
    ) {
        self._selection = selection
        self.collections = collections
        self.onCreate = onCreate
    }

    public var body: some View {
        Button {
            showsList = true
        } label: {
            HStack {
                Label {
                    CollectionPicker.title(selection)
                } icon: {
                    Image(systemName: "folder")
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showsList) {
            CollectionList(
                selection: $selection, collections: collections, onCreate: onCreate,
                dismiss: { showsList = false })
        }
    }

    static func title(_ path: CollectionPath) -> Text {
        if path == .root { return Text("Top level") }
        if path == .unsorted { return Text("Unsorted") }
        return Text(verbatim: path.components.joined(separator: " / "))
    }

    /// Every collection plus its ancestors, sorted so children follow their parent.
    static func tree(_ collections: [CollectionPath]) -> [CollectionPath] {
        var all = Set<CollectionPath>()
        for path in collections {
            var current: CollectionPath? = path
            while let node = current, node != .root {
                all.insert(node)
                current = node.parent
            }
        }
        return all.sorted { lhs, rhs in
            for (l, r) in zip(lhs.components, rhs.components) where l != r {
                return l.localizedStandardCompare(r) == .orderedAscending
            }
            return lhs.components.count < rhs.components.count
        }
    }
}

private struct CollectionList: View {
    @Binding var selection: CollectionPath
    let collections: [CollectionPath]
    let onCreate: ((String, CollectionPath) async -> CollectionPath?)?
    let dismiss: () -> Void
    @State private var asksName = false
    @State private var newName = ""
    @State private var created: [CollectionPath] = []

    var body: some View {
        NavigationStack {
            List {
                if onCreate != nil {
                    Button {
                        newName = ""
                        asksName = true
                    } label: {
                        Label("New collection…", systemImage: "folder.badge.plus")
                    }
                }
                if collections.contains(.root) {
                    row(.root, indent: 0)
                }
                ForEach(CollectionPicker.tree(collections + created), id: \.self) { path in
                    row(path, indent: path.components.count - 1)
                }
            }
            .navigationTitle("Collection")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: dismiss)
                }
            }
            .alert("New collection", isPresented: $asksName) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { create() }
            }
        }
    }

    private func row(_ path: CollectionPath, indent: Int) -> some View {
        Button {
            selection = path
            dismiss()
        } label: {
            HStack {
                Image(systemName: path == .root ? "square.stack" : "folder")
                    .foregroundStyle(.tint)
                if path == .root || path == .unsorted {
                    CollectionPicker.title(path)
                } else {
                    Text(verbatim: path.name)
                }
                Spacer()
                if path == selection {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
            .padding(.leading, CGFloat(indent) * 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let onCreate else { return }
        Task {
            if let path = await onCreate(name, .root) {
                created.append(path)
                selection = path
                dismiss()
            }
        }
    }
}
