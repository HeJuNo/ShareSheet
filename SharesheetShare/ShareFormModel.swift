import Foundation
import Observation
import QuickLookThumbnailing
import SharesheetCore
import SharesheetUI
import UIKit

/// State and actions of the share sheet: loads the payload, prefills the form, saves via the inbox.
@MainActor
@Observable
final class ShareFormModel {
    enum Phase { case loading, ready, empty }

    /// Lookups that must not keep the sheet from appearing.
    private static let lookupTimeout: Double = 1
    /// How long Save waits for the import into iCloud before closing.
    private static let importTimeout: Double = 3

    private(set) var phase = Phase.loading
    var state = SheetState(type: .link, title: "")
    private(set) var inputs: [SharedInput] = []
    private(set) var collections: [CollectionPath] = [.unsorted]
    private(set) var tagSuggestions: [String] = []
    private(set) var thumbnail: UIImage?
    private(set) var isSaving = false
    /// Attachments that could not be read; the rest can still be saved.
    private(set) var failedCount = 0
    /// Tag text typed but not yet committed with comma or return.
    var pendingTag = ""
    var errorMessage: LocalizedStringResource?

    @ObservationIgnored private var initial = SheetState(type: .link, title: "")
    private var existing: Item?
    @ObservationIgnored private var store: FolderItemStore?
    @ObservationIgnored private var previewImage: URL?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private let payloadLoader = SharedPayloadLoader()
    @ObservationIgnored private let previewLoader = LinkPreviewLoader()
    @ObservationIgnored private weak var context: NSExtensionContext?

    init(context: NSExtensionContext?) {
        self.context = context
    }

    var isMultiple: Bool { inputs.count > 1 }
    var canCreateCollections: Bool { store != nil }
    /// A re-share only writes the fields `SheetEdits` carries, which has no description.
    var isReshare: Bool { existing != nil }

    // MARK: Loading

    func load() async {
        guard phase == .loading else { return }
        let items = context?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let loaded = await payloadLoader.load(items)
        failedCount = loaded.failed
        let normalized = ShareRequestBuilder.normalized(loaded.inputs)
        inputs = normalized.inputs
        guard !inputs.isEmpty else {
            phase = .empty
            return
        }
        var lookupURL: URL?
        if inputs.count == 1, case .url(let url, _, _, _) = inputs[0] { lookupURL = url }

        // Independent lookups run side by side, each bounded, so none can hold up the sheet.
        async let tags = Self.loadTags()
        async let knownID = Self.indexedItemID(for: lookupURL)
        async let located = Self.locateLibrary()
        let (store, found) = await located
        self.store = store
        if let store, let id = await knownID {
            existing = await bounded(Self.lookupTimeout) { try? await store.item(id) } ?? nil
        }
        initial = ShareRequestBuilder.initialState(for: inputs, existing: existing, now: Date())
        state = initial
        if let note = normalized.note {
            state.note = state.note.isEmpty ? note : state.note + "\n\n" + note
        }
        collections = Self.collectionList(found, current: state.collection, multiple: isMultiple)
        tagSuggestions = await tags
        phase = .ready
        startPreview()
    }

    /// The library store and its collections, each step bounded.
    private nonisolated static func locateLibrary() async -> (FolderItemStore?, [CollectionPath]?) {
        guard let root = await bounded(lookupTimeout, { await ICloudLocator.libraryRoot() }) ?? nil else {
            return (nil, nil)
        }
        let store = FolderItemStore(root: root)
        let found = await bounded(lookupTimeout) { try? await store.collections() } ?? nil
        return (store, found)
    }

    /// Re-share detection through the read-only index; a full library scan would not fit the time bound.
    private nonisolated static func indexedItemID(for url: URL?) async -> ItemID? {
        guard let url, let path = AppGroup.indexURL() else { return nil }
        return await bounded(lookupTimeout) {
            try? LibraryIndex(path: path, readOnly: true).itemID(forURL: url)
        } ?? nil
    }

    private static func collectionList(
        _ found: [CollectionPath]?, current: CollectionPath, multiple: Bool
    ) -> [CollectionPath] {
        var result = found ?? [.unsorted]
        if !result.contains(.unsorted) { result.append(.unsorted) }
        if !result.contains(current) { result.append(current) }
        if multiple && !result.contains(.root) { result.append(.root) }
        return result
    }

    private nonisolated static func loadTags() async -> [String] {
        guard let path = AppGroup.indexURL() else { return [] }
        return (try? LibraryIndex(path: path, readOnly: true).allTags()) ?? []
    }

    private func startPreview() {
        switch inputs.first {
        case .url where !isMultiple:
            guard let url = state.url else { return }
            let directory = payloadLoader.temporaryDirectory
            let fillsTitle = existing == nil && state.title == url.host
            previewTask = Task { [weak self, previewLoader] in
                guard let preview = await previewLoader.load(url, into: directory), let self else { return }
                if fillsTitle, self.state.title == self.initial.title,
                   let title = preview.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                    self.state.title = title
                }
                if self.state.description == nil, let description = preview.description {
                    self.state.description = description
                }
                if let imageURL = preview.imageURL {
                    self.previewImage = imageURL
                    self.thumbnail = UIImage(contentsOfFile: imageURL.path)
                }
            }
        case .file(let url, _, _):
            previewTask = Task { [weak self] in
                let image = await Self.fileThumbnail(url)
                self?.thumbnail = image
            }
        default:
            break
        }
    }

    /// A small QuickLook thumbnail; the file itself is never loaded into memory.
    private nonisolated static func fileThumbnail(_ url: URL) async -> UIImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 72, height: 72), scale: 3, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage
    }

    // MARK: Actions

    func createCollection(named name: String, in parent: CollectionPath) async -> CollectionPath? {
        guard let store else { return nil }
        let created = await bounded(Self.importTimeout) {
            try? await store.createCollection(named: name, in: parent)
        } ?? nil
        if let created, !collections.contains(created) { collections.append(created) }
        return created
    }

    /// Enqueue (must succeed, else the sheet stays open with an error), then a bounded import, then close.
    func save() async {
        guard phase == .ready, !isSaving else { return }
        isSaving = true
        errorMessage = nil
        state.tags = TagField.adding(pendingTag, to: state.tags)
        pendingTag = ""
        previewTask?.cancel()
        previewLoader.cancel()
        guard let inboxRoot = AppGroup.inboxURL() else {
            fail()
            return
        }
        let (request, files) = ShareRequestBuilder.request(
            from: state, initial: initial, inputs: inputs, existing: existing, id: UUID(), now: Date(),
            previewImage: previewImage)
        do {
            try await Task.detached { try Inbox(root: inboxRoot).enqueue(request, files: files) }.value
        } catch {
            fail()
            return
        }
        payloadLoader.removeTemporaryFiles()
        let store = self.store
        _ = await bounded(Self.importTimeout) {
            let target: FolderItemStore? = if let store {
                store
            } else if let root = await ICloudLocator.libraryRoot() {
                FolderItemStore(root: root)
            } else {
                nil
            }
            guard let target else { return false }
            _ = await InboxImporter(inbox: Inbox(root: inboxRoot), store: target).importRequest(request.id)
            return true
        }
        context?.completeRequest(returningItems: nil)
    }

    func cancel() {
        previewTask?.cancel()
        previewLoader.cancel()
        payloadLoader.removeTemporaryFiles()
        context?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }

    private func fail() {
        errorMessage = "Couldn’t save. Please try again."
        isSaving = false
    }
}
