import SharesheetCore
import SwiftUI

/// The items of one scope, newest first, searchable and filterable by tag.
struct ItemListView: View {
    @Environment(AppModel.self) private var model
    let query: LibraryQuery
    @State private var searchText = ""
    @State private var tag: String?

    var body: some View {
        ItemResults(query: effectiveQuery)
            .navigationTitle(Self.title(query.scope))
            .searchable(text: $searchText, prompt: Text("Search"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    TagFilterMenu(selection: $tag, tags: TagFilterMenu.tags(of: model.items(untaggedQuery), in: model.tags))
                }
            }
            .refreshable { await model.refresh() }
    }

    private var untaggedQuery: LibraryQuery {
        var result = query
        let text = searchText.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { result.text = text }
        return result
    }

    private var effectiveQuery: LibraryQuery {
        var result = untaggedQuery
        if let tag { result.tag = tag }
        return result
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

/// A toolbar menu choosing one tag (or none) to narrow a list.
struct TagFilterMenu: View {
    @Binding var selection: String?
    let tags: [String]

    var body: some View {
        Menu {
            Picker(selection: $selection) {
                Text("All tags").tag(String?.none)
                ForEach(tags, id: \.self) { tag in
                    Text(verbatim: tag).tag(Optional(tag))
                }
            } label: {
                Text("Tag")
            }
        } label: {
            Label("Filter by tag", systemImage: selection == nil ? "tag" : "tag.fill")
        }
    }

    /// The tags used by `items`, in the order of `all` (most used first), without case duplicates.
    static func tags(of items: [IndexedItem], in all: [String]) -> [String] {
        let used = Set(items.flatMap(\.tags).map { $0.lowercased() })
        var seen = Set<String>()
        return all.filter { used.contains($0.lowercased()) && seen.insert($0.lowercased()).inserted }
    }
}

/// A list of the items matching a query, with favorite and delete swipe actions.
/// Used by the scope lists and by the home search.
struct ItemResults: View {
    private enum Failure {
        case favorite, delete

        var title: Text {
            switch self {
            case .favorite: Text("Couldn’t change the favorite")
            case .delete: Text("Couldn’t delete the item")
            }
        }
    }

    @Environment(AppModel.self) private var model
    let query: LibraryQuery
    @State private var pendingDelete: IndexedItem?
    @State private var failure: Failure?

    var body: some View {
        let items = model.items(query)
        List {
            ForEach(items) { item in
                NavigationLink {
                    // Replaced by the item screen.
                    Text(verbatim: item.title)
                } label: {
                    ItemRow(item: item, favicon: model.favicon(for: item))
                }
                .swipeActions(edge: .leading) {
                    Button {
                        toggleFavorite(item)
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
            }
        }
        .listStyle(.plain)
        .overlay {
            if items.isEmpty {
                if let text = query.text {
                    ContentUnavailableView.search(text: text)
                } else {
                    ContentUnavailableView("No items", systemImage: "tray")
                }
            }
        }
        .confirmationDialog(
            "Delete this item?", isPresented: isPresented($pendingDelete), titleVisibility: .visible,
            presenting: pendingDelete
        ) { item in
            Button("Delete", role: .destructive) { delete(item) }
        } message: { item in
            Text(verbatim: item.title)
        }
        .alert(failure?.title ?? Text(verbatim: ""), isPresented: isPresented($failure)) {
            Button("OK") {}
        }
    }

    private func toggleFavorite(_ item: IndexedItem) {
        Task {
            do { try await model.toggleFavorite(item) } catch { failure = .favorite }
        }
    }

    private func delete(_ item: IndexedItem) {
        Task {
            do { try await model.delete(item) } catch { failure = .delete }
        }
    }

    private func isPresented<T>(_ value: Binding<T?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }
}
