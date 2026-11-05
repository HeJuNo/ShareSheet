import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Sharesheet
import SharesheetCore

@MainActor
struct SharedPayloadLoaderTests {
    /// Facebook's app shares a post with an attachment that cannot be read and the link only in the text.
    @Test func linkInTheTextReplacesAnUnreadableAttachmentWithoutAWarning() async throws {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(for: .url, visibility: .all) { completion in
            completion(nil, CocoaError(.fileReadUnknown))
            return nil
        }
        let item = NSExtensionItem()
        item.attachments = [provider]
        item.attributedContentText = NSAttributedString(string: "https://www.facebook.com/share/p/1MPxGxwctR/?mibextid=wwXIfr")
        let loader = SharedPayloadLoader()
        defer { loader.removeTemporaryFiles() }

        let loaded = await loader.load([item])

        #expect(loaded.failed == 0)
        guard case .url(let url, _, _, _) = try #require(loaded.inputs.first) else {
            Issue.record("expected a link, got \(loaded.inputs)")
            return
        }
        #expect(url.absoluteString == "https://www.facebook.com/share/p/1MPxGxwctR/?mibextid=wwXIfr")
    }

    // MARK: Plain text

    private func share(_ provider: NSItemProvider, text: String? = nil) -> NSExtensionItem {
        let item = NSExtensionItem()
        item.attachments = [provider]
        if let text { item.attributedContentText = NSAttributedString(string: text) }
        return item
    }

    private func texts(_ inputs: [SharedInput]) -> [String] {
        inputs.compactMap { if case .text(let text) = $0 { text } else { nil } }
    }

    /// Some apps register `public.plain-text` only as a file, which `loadObject(ofClass: String.self)` cannot read.
    @Test func plainTextOfferedOnlyAsAFileIsReadAsText() async throws {
        let provider = NSItemProvider()
        provider.registerFileRepresentation(for: .plainText, visibility: .all) { completion in
            let url = FileManager.default.temporaryDirectory.appending(path: "shared-\(UUID().uuidString)")
            try? Data("Hello from a file".utf8).write(to: url)
            completion(url, false, nil)
            return nil
        }
        let loader = SharedPayloadLoader()
        defer { loader.removeTemporaryFiles() }
        let loaded = await loader.load([share(provider)])
        #expect(loaded.failed == 0)
        #expect(texts(loaded.inputs) == ["Hello from a file"])
    }

    /// The text also arrives as the share's own text; it is used when the attachment cannot be read.
    @Test func theSharesOwnTextReplacesAnUnreadablePlainTextAttachment() async throws {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(for: .plainText, visibility: .all) { completion in
            completion(nil, CocoaError(.fileReadUnknown))
            return nil
        }
        let loader = SharedPayloadLoader()
        defer { loader.removeTemporaryFiles() }
        let loaded = await loader.load([share(provider, text: "Hello from the share")])
        #expect(loaded.failed == 0)
        #expect(texts(loaded.inputs) == ["Hello from the share"])
    }

    @Test func anUnreadablePlainTextAttachmentWithoutOtherTextStillCountsAsFailed() async throws {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(for: .plainText, visibility: .all) { completion in
            completion(nil, CocoaError(.fileReadUnknown))
            return nil
        }
        let loader = SharedPayloadLoader()
        defer { loader.removeTemporaryFiles() }
        let loaded = await loader.load([share(provider, text: "   ")])
        #expect(loaded.inputs.isEmpty && loaded.failed == 1)
    }

    @Test func plainTextAsDataStillWorks() async throws {
        let provider = NSItemProvider(item: "Plain snippet" as NSString, typeIdentifier: UTType.plainText.identifier)
        let loader = SharedPayloadLoader()
        defer { loader.removeTemporaryFiles() }
        let loaded = await loader.load([share(provider)])
        #expect(texts(loaded.inputs) == ["Plain snippet"])
    }
}
