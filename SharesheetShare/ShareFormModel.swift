import Foundation
import Observation
import QuickLookThumbnailing
import SharesheetCore
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
        inputs = ShareRequestBuilder.normalized((try? await payloadLoader.load(items)) ?? [])
        guard !inputs.isEmpty else {
            phase = .empty
            return
        }
        async let tags = Self.loadTags()
        store = await bounded(Self.lookupTimeout) { await ICloudLocator.libraryRoot() }
            .flatMap { $0 }.map { FolderItemStore(root: $0) }
        if let store, inputs.count == 1, case .url(let url, _, _) = inputs[0] {
            existing = await bounded(Self.lookupTimeout) { try? await store.findItem(url: url) } ?? nil
        }
        initial = ShareRequestBuilder.initialState(for: inputs, existing: existing, now: Date())
        state = initial
        collections = await loadCollections()
        tagSuggestions = await tags
        phase = .ready
        startPreview()
    }

    private func loadCollections() async -> [CollectionPath] {
        var result: [CollectionPath] = [.unsorted]
        if let store, let found = await bounded(Self.lookupTimeout, { try? await store.collections() }) ?? nil {
            result = found
        }
        if !result.contains(.unsorted) { result.append(.unsorted) }
        if !result.contains(state.collection) { result.append(state.collection) }
        if isMultiple && !result.contains(.root) { result.append(.root) }
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
            _ = await InboxImporter(inbox: Inbox(root: inboxRoot), store: target).importAll()
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
