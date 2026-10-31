import SharesheetCore
import SharesheetUI
import SwiftUI

/// The Raindrop-style share sheet: header, card, collection, tags, highlights, favorite and URL.
struct ShareFormView: View {
    @Bindable var model: ShareFormModel

    var body: some View {
        NavigationStack {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
        .task { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView()
        case .empty:
            ContentUnavailableView("Nothing to save", systemImage: "tray")
        case .ready:
            form
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                model.cancel()
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel(Text("Cancel"))
        }
        ToolbarItem(placement: .principal) {
            typeMenu
        }
        ToolbarItem(placement: .confirmationAction) {
            if model.isSaving {
                ProgressView()
            } else {
                Button("Save") {
                    Task { await model.save() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.phase != .ready)
            }
        }
    }

    private var typeMenu: some View {
        Menu {
            Picker(selection: $model.state.type) {
                ForEach(ItemType.allCases, id: \.self) { type in
                    Label {
                        Text(type.label)
                    } icon: {
                        ItemTypeIcon(type)
                    }
                    .tag(type)
                }
            } label: {
                EmptyView()
            }
        } label: {
            HStack(spacing: 4) {
                ItemTypeIcon(model.state.type)
                Text("New \(Text(model.state.type.label))")
                    .font(.headline)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.primary)
        }
        .disabled(model.phase != .ready)
    }

    private var form: some View {
        Form {
            if let error = model.errorMessage {
                Section {
                    Label {
                        Text(error)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.red)
                }
            }
            cardSection
            collectionSection
            Section("Tags") {
                TagField(tags: $model.state.tags, suggestions: model.tagSuggestions)
            }
            if let highlight = model.state.highlight {
                Section("Highlights") {
                    Text(verbatim: highlight)
                        .italic()
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) {
                            Capsule().fill(.yellow).frame(width: 3)
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) { model.state.highlight = nil }
                        }
                }
            }
            Section {
                Toggle(isOn: $model.state.favorite) {
                    Label("Favorite", systemImage: model.state.favorite ? "heart.fill" : "heart")
                }
                if let url = model.state.url {
                    Label {
                        Text(verbatim: url.absoluteString)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    } icon: {
                        Image(systemName: "link")
                    }
                }
            }
        }
        .disabled(model.isSaving)
    }

    private var cardSection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    if model.isMultiple {
                        Text("\(model.inputs.count) items")
                            .font(.headline)
                    } else {
                        TextField("Title", text: $model.state.title, axis: .vertical)
                            .font(.headline)
                            .lineLimit(1...3)
                        TextField("Description", text: descriptionBinding, axis: .vertical)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1...4)
                            .disabled(model.isReshare)
                    }
                }
                Spacer(minLength: 0)
                thumbnail
            }
            TextField("Note", text: $model.state.note, axis: .vertical)
                .lineLimit(2...8)
        }
    }

    private var thumbnail: some View {
        Group {
            if let image = model.thumbnail {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ItemTypeIcon(model.state.type)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var collectionSection: some View {
        Section {
            if model.state.newCollectionName != nil {
                TextField("New collection", text: newCollectionBinding)
            }
            CollectionPicker(
                selection: $model.state.collection, collections: model.collections,
                onCreate: model.canCreateCollections
                    ? { name, parent in await model.createCollection(named: name, in: parent) }
                    : nil)
        }
    }

    private var descriptionBinding: Binding<String> {
        Binding(
            get: { model.state.description ?? "" },
            set: { model.state.description = $0.isEmpty ? nil : $0 })
    }

    private var newCollectionBinding: Binding<String> {
        Binding(
            get: { model.state.newCollectionName ?? "" },
            set: { model.state.newCollectionName = $0 })
    }
}
