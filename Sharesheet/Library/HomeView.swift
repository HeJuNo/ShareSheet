import SharesheetCore
import SharesheetUI
import SwiftUI

/// The library home: the fixed scopes, the collection tree, type filters and a search over everything.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var searchText = ""
    @State private var showsSettings = false
    @State private var asksCollectionName = false
    @State private var newCollectionName = ""
    @State private var searchTag: String?
    @State private var collectionFailed = false
    @State private var pendingCollectionDelete: CollectionPath?
    @State private var collectionDeleteFailure: CollectionDeleteFailure?

    private enum CollectionDeleteFailure {
        /// A plain delete found content; the alert offers moving it to Unsorted.
        case notEmpty(CollectionPath)
        case other

        var title: Text {
            switch self {
            case .notEmpty: Text("Collection isn’t empty")
            case .other: Text("Couldn’t delete the collection")
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let query = searchQuery {
                    ItemResults(query: query)
                } else {
                    List {
                        if model.iCloudState == .unavailable {
                            Section {
                                Label("iCloud unavailable", systemImage: "icloud.slash")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        library
                    }
                }
            }
            .navigationTitle("Sharesheet")
            .navigationDestination(for: LibraryScope.self) { scope in
                ItemListView(query: LibraryQuery(scope: scope))
            }
            .navigationDestination(for: ItemID.self) { id in
                ItemDetailView(id: id)
            }
            .searchable(text: $searchText, prompt: Text("Search"))
            .onChange(of: searchText) { _, text in
                if text.trimmingCharacters(in: .whitespaces).isEmpty { searchTag = nil }
            }
            .toolbar {
                if let query = searchQuery {
                    ToolbarItem(placement: .topBarTrailing) {
                        TagFilterMenu(selection: $searchTag, tags: TagFilterMenu.tags(of: model.items(untagged(query)), in: model.tags))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .refreshable { await model.refresh() }
            .sheet(isPresented: $showsSettings) { SettingsView() }
            .alert("New collection", isPresented: $asksCollectionName) {
                TextField("Name", text: $newCollectionName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { createCollection() }
            }
            .alert("Couldn’t create the collection", isPresented: $collectionFailed) {
                Button("OK") {}
            }
            .confirmationDialog(
                "Delete this collection?", isPresented: $pendingCollectionDelete.isPresent(),
                titleVisibility: .visible, presenting: pendingCollectionDelete
            ) { path in
                if (model.counts.byCollection[path] ?? 0) == 0 {
                    Button("Delete", role: .destructive) { deleteCollection(path, moveItemsToUnsorted: false) }
                } else {
                    Button("Move items to Unsorted and delete", role: .destructive) {
                        deleteCollection(path, moveItemsToUnsorted: true)
                    }
                }
            } message: { path in
                Text(verbatim: path.components.joined(separator: " / "))
            }
            .alert(
                collectionDeleteFailure?.title ?? Text(verbatim: ""), isPresented: $collectionDeleteFailure.isPresent(),
                presenting: collectionDeleteFailure
            ) { failure in
                if case .notEmpty(let path) = failure {
                    Button("Move items to Unsorted and delete", role: .destructive) {
                        deleteCollection(path, moveItemsToUnsorted: true)
                    }
                    Button("Cancel", role: .cancel) {}
                } else {
                    Button("OK") {}
                }
            }
        }
    }

    @ViewBuilder private var library: some View {
        Section {
            ScopeRow(scope: .all, count: model.counts.all) { Image(systemName: "tray.full") }
            ScopeRow(scope: .unsorted, count: model.counts.unsorted) { Image(systemName: "tray") }
            ScopeRow(scope: .favorites, count: model.counts.favorites) { Image(systemName: "star") }
        }
        Section {
            ForEach(children(of: .root), id: \.self) { path in
                CollectionNode(
                    path: path, children: children(of:), count: { model.counts.byCollection[$0] ?? 0 },
                    onDelete: { pendingCollectionDelete = $0 })
            }
        } header: {
            HStack {
                Text("Collections")
                Spacer()
                Button {
                    newCollectionName = ""
                    asksCollectionName = true
                } label: {
                    Label("New collection", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .disabled(!model.isICloudAvailable)
            }
        }
        Section("Filters") {
            ScopeRow(scope: .highlights, count: model.counts.highlights) { Image(systemName: "highlighter") }
            ForEach(ItemType.allCases.filter { (model.counts.byType[$0] ?? 0) > 0 }, id: \.self) { type in
                ScopeRow(scope: .type(type), count: model.counts.byType[type] ?? 0) { ItemTypeIcon(type) }
            }
        }
    }

    /// The search over all items, nil while the search field is empty.
    private var searchQuery: LibraryQuery? {
        let text = searchText.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : LibraryQuery(text: text, scope: .all, tag: searchTag)
    }

    private func untagged(_ query: LibraryQuery) -> LibraryQuery {
        var result = query
        result.tag = nil
        return result
    }

    /// Direct sub-collections; `Unsorted` is listed with the fixed scopes instead.
    private func children(of parent: CollectionPath) -> [CollectionPath] {
        model.collections.filter { $0.parent == parent && $0 != .unsorted }
    }

    private func deleteCollection(_ path: CollectionPath, moveItemsToUnsorted: Bool) {
        Task {
            do {
                try await model.deleteCollection(path, moveItemsToUnsorted: moveItemsToUnsorted)
            } catch StoreError.collectionNotEmpty where !moveItemsToUnsorted {
                collectionDeleteFailure = .notEmpty(path)
            } catch {
                collectionDeleteFailure = .other
            }
        }
    }

    private func createCollection() {
        let name = newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                _ = try await model.createCollection(named: name, in: .root)
            } catch {
                collectionFailed = true
            }
        }
    }
}

private struct ScopeRow<Icon: View>: View {
    let scope: LibraryScope
    let count: Int
    @ViewBuilder let icon: Icon

    var body: some View {
        NavigationLink(value: scope) {
            HStack {
                Label {
                    ItemListView.title(scope)
                } icon: {
                    icon
                }
                Spacer()
                Text(count, format: .number)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A collection with its nested collections in a disclosure group; swipe or long-press to delete it.
private struct CollectionNode: View {
    let path: CollectionPath
    let children: (CollectionPath) -> [CollectionPath]
    let count: (CollectionPath) -> Int
    let onDelete: (CollectionPath) -> Void

    var body: some View {
        let nested = children(path)
        if nested.isEmpty {
            row
        } else {
            DisclosureGroup {
                ForEach(nested, id: \.self) { child in
                    CollectionNode(path: child, children: children, count: count, onDelete: onDelete)
                }
            } label: {
                row
            }
        }
    }

    private var row: some View {
        ScopeRow(scope: .collection(path), count: count(path)) { Image(systemName: "folder") }
            .swipeActions(edge: .trailing) {
                Button {
                    onDelete(path)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
            }
            .contextMenu {
                Button(role: .destructive) {
                    onDelete(path)
                } label: {
                    Label("Delete collection", systemImage: "trash")
                }
            }
    }
}
