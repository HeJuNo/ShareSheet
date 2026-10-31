import SharesheetCore
import SwiftUI

/// The items of one scope, newest first, searchable and filterable by tag.
struct ItemListView: View {
    @Environment(AppModel.self) private var model
    let query: LibraryQuery
    @State private var searchText = ""
    @State private var tag: String?

    var body: some View {
        let current = effectiveQuery
        List {
            ItemResults(query: current)
        }
        .listStyle(.plain)
        .overlay {
            if model.items(current).isEmpty {
                if searchText.isEmpty {
                    ContentUnavailableView("No items", systemImage: "tray")
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
        .navigationTitle(Self.title(query.scope))
        .searchable(text: $searchText, prompt: Text("Search"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { tagMenu }
        }
        .refreshable { await model.refresh() }
    }

    private var effectiveQuery: LibraryQuery {
        var result = query
        let text = searchText.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { result.text = text }
        if let tag { result.tag = tag }
        return result
    }

    /// Tags used by items of this scope, most used first.
    private var scopeTags: [String] {
        var unfiltered = effectiveQuery
        unfiltered.tag = query.tag
        let used = Set(model.items(unfiltered).flatMap(\.tags).map { $0.lowercased() })
        var seen = Set<String>()
        return model.tags.filter { used.contains($0.lowercased()) && seen.insert($0.lowercased()).inserted }
    }

    private var tagMenu: some View {
        Menu {
            Picker(selection: $tag) {
                Text("All tags").tag(String?.none)
                ForEach(scopeTags, id: \.self) { tag in
                    Text(verbatim: tag).tag(Optional(tag))
                }
            } label: {
                Text("Tag")
            }
        } label: {
            Label("Filter by tag", systemImage: tag == nil ? "tag" : "tag.fill")
        }
    }

    static func title(_ scope: LibraryScope) -> Text {
        switch scope {
        case .all: Text("All")
        case .unsorted: Text("Unsorted")
        case .favorites: Text("Favorites")
        case .highlights: Text("Highlights")
        case .type(let type): Text(type.label)
        case .collection(let path): Text(verbatim: path.name)
        }
    }
}

/// Rows for a query, with favorite and delete swipe actions. Used by the list and by the home search.
struct ItemResults: View {
    @Environment(AppModel.self) private var model
    let query: LibraryQuery
    @State private var pendingDelete: IndexedItem?

    var body: some View {
        Group {
            ForEach(model.items(query)) { item in
                NavigationLink {
                    // Replaced by the item screen.
                    Text(verbatim: item.title)
                } label: {
                    ItemRow(item: item, favicon: model.favicon(for: item))
                }
                .swipeActions(edge: .leading) {
                    Button {
                        Task { await model.toggleFavorite(item) }
                    } label: {
                        if item.favorite {
                            Label("Unfavorite", systemImage: "star.slash")
                        } else {
                            Label("Favorite", systemImage: "star")
                        }
                    }
                    .tint(.yellow)
                }
                .swipeActions(edge: .trailing) {
                    Button {
                        pendingDelete = item
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(.red)
                }
                .confirmationDialog(
                    "Delete this item?", isPresented: isConfirmingDelete(item), titleVisibility: .visible,
                    presenting: item
                ) { item in
                    Button("Delete", role: .destructive) {
                        Task { await model.delete(item) }
                    }
                } message: { item in
                    Text(verbatim: item.title)
                }
            }
        }
    }

    private func isConfirmingDelete(_ item: IndexedItem) -> Binding<Bool> {
        Binding(get: { pendingDelete?.id == item.id }, set: { if !$0 { pendingDelete = nil } })
    }
}
