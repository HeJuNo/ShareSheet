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
}
