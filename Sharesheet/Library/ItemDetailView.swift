import SharesheetCore
import SharesheetUI
import SwiftUI

/// One item: its screenshot, file or text on top, then title, note, tags, favorite, collection, highlights,
/// the archive and Open in Safari. Edits are saved 1 s after the last change and when leaving the screen.
struct ItemDetailView: View {
    /// The fields the user edits here; everything else on the item belongs to the store and the capture runner.
    private struct Edits: Equatable {
        var title: String
        var note: String
        var tags: [String]
        var favorite: Bool

        init(_ item: Item) {
            title = item.title
            note = item.note
            tags = item.tags
            favorite = item.favorite
        }

        func apply(to item: inout Item) {
            item.title = title
            item.note = note
            item.tags = tags
            item.favorite = favorite
        }
    }

    private enum Failure {
        case gone, load, save, move, delete, createCollection

        var title: Text {
            switch self {
            case .gone: Text("This item no longer exists")
            case .load: Text("Couldn’t open the item")
            case .save: Text("Couldn’t save the item")
            case .move: Text("Couldn’t move the item")
            case .delete: Text("Couldn’t delete the item")
            case .createCollection: Text("Couldn’t create the collection")
            }
        }

        var leavesScreen: Bool { self == .gone || self == .load }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var id: ItemID
    @State private var collection: CollectionPath
    @State private var item: Item?
    /// The edit fields as last read from or written to the file.
    @State private var baseline: Edits?
    @State private var pendingTag = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var isGone = false
    @State private var isCapturing = false
    @State private var confirmsDelete = false
    @State private var failure: Failure?

    init(id: ItemID) {
        _id = State(initialValue: id)
        _collection = State(initialValue: id.collection)
    }

    var body: some View {
        Group {
            if let item {
                content(item)
            } else {
                ProgressView()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    confirmsDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(item == nil)
            }
        }
        .task { await load() }
        .onChange(of: item.map(Edits.init)) { scheduleSave() }
        .onChange(of: collection) { _, destination in
            guard destination != id.collection else { return }
            Task { await move(to: destination) }
        }
        .onDisappear { flush(committingPendingTag: true) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { flush(committingPendingTag: false) }
        }
        .confirmationDialog("Delete this item?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await delete() } }
        } message: {
            Text(verbatim: item?.title ?? "")
        }
        .alert(failure?.title ?? Text(verbatim: ""), isPresented: $failure.isPresent(), presenting: failure) { failure in
            Button("OK") { if failure.leavesScreen { dismiss() } }
        }
    }

    private func content(_ item: Item) -> some View {
        List {
            Section {
                header(item)
                    .listRowInsets(EdgeInsets())
                TextField("Title", text: binding(\.title), axis: .vertical)
                    .font(.title3.bold())
                metadata(item)
            }
            if item.capture == .failed, item.screenshot != nil {
                Section { retryRow }
            }
            Section("Note") {
                TextField("Add a note", text: binding(\.note), axis: .vertical)
                    .lineLimit(3...)
            }
            Section("Tags") {
                TagField(tags: binding(\.tags), suggestions: model.tags, pending: $pendingTag)
            }
            Section {
                Toggle(isOn: binding(\.favorite)) {
                    Label("Favorite", systemImage: "star")
                }
            }
            Section("Collection") {
                CollectionPicker(selection: $collection, collections: model.collections) { name, parent in
                    do {
                        return try await model.createCollection(named: name, in: parent)
                    } catch {
                        failure = .createCollection
                        return nil
                    }
                }
            }
            if !item.highlights.isEmpty {
                Section("Highlights") {
                    ForEach(Array(item.highlights.enumerated()), id: \.offset) { _, highlight in
                        Text(verbatim: highlight)
                            .italic()
                            .padding(.leading, 10)
                            .overlay(alignment: .leading) {
                                Capsule().fill(.purple).frame(width: 3)
                            }
                    }
                }
            }
            if item.archive != nil || item.url != nil {
                Section {
                    if let archive = item.archive {
                        NavigationLink {
                            ArchiveViewer(relativePath: archive)
                        } label: {
                            Label("View archive", systemImage: "doc.richtext")
                        }
                    }
                    if let url = item.url {
                        Button {
                            openURL(url)
                        } label: {
                            Label("Open in Safari", systemImage: "safari")
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    /// The screenshot for web items, the file itself for files, the shared text for text items.
    @ViewBuilder private func header(_ item: Item) -> some View {
        if let file = item.file {
            FileHeader(relativePath: file)
        } else if let screenshot = item.screenshot {
            ScreenshotThumbnail(relativePath: screenshot)
        } else if item.url != nil {
            switch item.capture {
            case .failed:
                placeholder("Capture failed", systemImage: "exclamationmark.triangle") { retryButton("Retry") }
            case .done:
                placeholder("File missing", systemImage: "photo") { EmptyView() }
            case .pending, nil:
                placeholder("Capture pending", systemImage: "hourglass") { retryButton("Capture now") }
            }
        } else if let content = item.content, !content.isEmpty {
            Text(verbatim: content)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
    }

    private func placeholder<Actions: View>(
        _ title: LocalizedStringKey, systemImage: String, @ViewBuilder actions: () -> Actions
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } actions: {
            actions()
        }
        .frame(minHeight: 200)
    }

    private func retryButton(_ title: LocalizedStringKey) -> some View {
        Button {
            Task { await capture() }
        } label: {
            if isCapturing {
                ProgressView()
            } else {
                Text(title)
            }
        }
        .buttonStyle(.bordered)
        .disabled(isCapturing || model.runner == nil)
    }

    private var retryRow: some View {
        HStack {
            Label("Capture failed", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            Spacer()
            retryButton("Retry")
        }
    }

    private func metadata(_ item: Item) -> some View {
        HStack(spacing: 4) {
            if let domain = Self.domain(of: item.url) {
                Text(verbatim: domain)
                Text(verbatim: "·")
            }
            if id.collection == .unsorted {
                Text("Unsorted")
            } else {
                Text(verbatim: id.collection.components.joined(separator: " / "))
            }
            Text(verbatim: "·")
            Text(item.created, format: .dateTime.day().month().year().hour().minute())
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private static func domain(of url: URL?) -> String? {
        guard var host = url?.host(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<Item, Value>) -> Binding<Value> {
        Binding(
            get: { item![keyPath: keyPath] },
            set: { item?[keyPath: keyPath] = $0 })
    }

    // MARK: Loading and saving

    private func load() async {
        guard item == nil else { return }
        do {
            let loaded = try await model.loadItem(id)
            item = loaded
            baseline = Edits(loaded)
        } catch StoreError.notFound {
            failure = .gone
        } catch {
            failure = .load
        }
    }

    /// Takes the file's version of `loaded`, keeping edits made since `reference`: the snapshot that was
    /// saved, or the baseline when nothing was.
    private func merge(_ loaded: Item, since reference: Edits?) {
        var merged = loaded
        if let current = item, let reference, Edits(current) != reference {
            Edits(current).apply(to: &merged)
        }
        merged.id = id
        item = merged
        baseline = Edits(loaded)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        guard let item, let baseline, Edits(item) != baseline else { return }
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    /// Saves now, without waiting for the debounce. The snapshot is taken before any suspension, so
    /// it is what the screen showed when leaving it or going to the background.
    private func flush(committingPendingTag: Bool) {
        saveTask?.cancel()
        guard !isGone, var snapshot = item, let baseline else { return }
        if committingPendingTag, !pendingTag.trimmingCharacters(in: .whitespaces).isEmpty {
            snapshot.tags = TagField.adding(pendingTag, to: snapshot.tags)
            item = snapshot
        }
        guard Edits(snapshot) != baseline else { return }
        Task { await persist(snapshot) }
    }

    private func save() async {
        guard !isGone, let snapshot = item, let baseline, Edits(snapshot) != baseline else { return }
        await persist(snapshot)
    }

    private func persist(_ snapshot: Item) async {
        do {
            merge(try await model.save(snapshot), since: Edits(snapshot))
        } catch StoreError.notFound {
            isGone = true
            failure = .gone
        } catch {
            failure = .save
        }
    }

    private func move(to destination: CollectionPath) async {
        saveTask?.cancel()
        await save()
        guard !isGone else { return }
        do {
            let newID = try await model.move(id, to: destination)
            id = newID
            item?.id = newID
        } catch StoreError.notFound {
            isGone = true
            failure = .gone
        } catch {
            failure = .move
            collection = id.collection
        }
    }

    private func delete() async {
        saveTask?.cancel()
        do {
            try await model.delete(id)
            isGone = true
            dismiss()
        } catch {
            failure = .delete
        }
    }

    private func capture() async {
        isCapturing = true
        await model.retryCapture(id)
        isCapturing = false
        if let loaded = try? await model.loadItem(id) { merge(loaded, since: baseline) }
    }
}

/// A file item's attachment in Quick Look, or "File missing".
private struct FileHeader: View {
    let relativePath: String
    @Environment(AppModel.self) private var model
    @State private var url: URL?
    @State private var resolved = false

    var body: some View {
        Group {
            if let url {
                FilePreview(url: url)
            } else if resolved {
                ContentUnavailableView("File missing", systemImage: "doc")
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 360)
        .task(id: relativePath) {
            url = await model.attachmentURL(relativePath)
            resolved = true
        }
    }
}
