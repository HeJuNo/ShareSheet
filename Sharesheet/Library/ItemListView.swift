import SharesheetCore
import SwiftUI

/// The items of one scope, newest first, searchable and filterable by tag.
struct ItemListView: View {
    @Environment(AppModel.self) private var model
    let query: LibraryQuery
    @State private var searchText = ""
    @State private var tagFilter = TagFilter()

    var body: some View {
        ItemResults(query: effectiveQuery)
            .navigationTitle(Self.title(query.scope))
            .searchable(text: $searchText, prompt: Text("Search"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    TagFilterMenu(filter: $tagFilter, tags: TagFilterMenu.tags(of: model.items(untaggedQuery), in: model.tags))
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
        tagFilter.apply(to: &result)
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

/// The tags a list must carry and the tags it must not carry.
struct TagFilter: Equatable {
    var included: [String] = []
    var excluded: [String] = []

    var isEmpty: Bool { included.isEmpty && excluded.isEmpty }

    func apply(to query: inout LibraryQuery) {
        query.tags = included
        query.excludedTags = excluded
    }

    func includes(_ tag: String) -> Bool { included.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
    func excludes(_ tag: String) -> Bool { excluded.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }

    /// Tapping a tag in "With" or "Without" switches it on, or off when it is already on there; a tag is never in both.
    mutating func toggleIncluded(_ tag: String) {
        excluded.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
        if includes(tag) { included.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame } } else { included.append(tag) }
    }

    mutating func toggleExcluded(_ tag: String) {
        included.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
        if excludes(tag) { excluded.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame } } else { excluded.append(tag) }
    }
}

/// A toolbar menu choosing tags an item must carry ("With") and tags it must not carry ("Without").
struct TagFilterMenu: View {
    @Binding var filter: TagFilter
    let tags: [String]

    var body: some View {
        Menu {
            Button("All tags") { filter = TagFilter() }
                .disabled(filter.isEmpty)
            Section("With") {
                ForEach(tags, id: \.self) { tag in
                    Toggle(isOn: Binding(get: { filter.includes(tag) }, set: { _ in filter.toggleIncluded(tag) })) {
                        Text(verbatim: tag)
                    }
                }
            }
            Section("Without") {
                ForEach(tags, id: \.self) { tag in
                    Toggle(isOn: Binding(get: { filter.excludes(tag) }, set: { _ in filter.toggleExcluded(tag) })) {
                        Text(verbatim: tag)
                    }
                }
            }
        } label: {
            Label("Filter by tag", systemImage: filter.isEmpty ? "tag" : "tag.fill")
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
    @State private var failure: Failure?

    var body: some View {
        let items = model.items(query)
        List {
            ForEach(items) { item in
                NavigationLink(value: item.id) {
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
                    // No confirmation: the item goes to the Trash, and the banner offers Undo.
                    Button(role: .destructive) {
                        delete(item)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .safeAreaInset(edge: .bottom) { FieldStatsBar(stats: model.fieldStats(query)) }
        .overlay {
            if items.isEmpty {
                if let text = query.text {
                    ContentUnavailableView.search(text: text)
                } else {
                    ContentUnavailableView("No items", systemImage: "tray")
                }
            }
        }
        .alert(failure?.title ?? Text(verbatim: ""), isPresented: $failure.isPresent()) {
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
}

/// One row per number field of the listed items: its name and result, and below it which aggregate that is and
/// over how many items. Two rows at most; "N more" opens the rest.
struct FieldStatsBar: View {
    let stats: [FieldStat]
    @State private var showsAll = false
    private let visibleRows = 2

    var body: some View {
        if !stats.isEmpty {
            VStack(spacing: 8) {
                ForEach(stats.prefix(visibleRows)) { FieldStatRow(stat: $0) }
                if stats.count > visibleRows {
                    Button {
                        showsAll = true
                    } label: {
                        Text("\(stats.count - visibleRows) more")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.bar)
            .sheet(isPresented: $showsAll) {
                NavigationStack {
                    List(stats) { FieldStatRow(stat: $0) }
                        .navigationTitle("Fields")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) { Button("Done") { showsAll = false } }
                        }
                }
                .presentationDetents([.medium, .large])
            }
        }
    }
}

struct FieldStatRow: View {
    let stat: FieldStat

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: stat.name)
                    .font(.subheadline)
                (Text(stat.aggregate.title) + Text(verbatim: " · ") + Text("\(stat.count) items"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(verbatim: stat.value?.formatted(.number.precision(.fractionLength(0...2))) ?? "–")
                .font(.headline.monospacedDigit())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: stat.name))
        .accessibilityValue(valueDescription)
    }

    private var valueDescription: Text {
        let value = stat.value?.formatted(.number.precision(.fractionLength(0...2))) ?? String(localized: "no value")
        return Text(stat.aggregate.title) + Text(verbatim: " \(value), ") + Text("\(stat.count) items")
    }
}
