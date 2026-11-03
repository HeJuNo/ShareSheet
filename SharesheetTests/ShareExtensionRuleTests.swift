import Foundation
import Testing

/// Safari hands an extension with a preprocessing script only the script's results, and on a PDF the script
/// never runs, so the PDF never arrives. A second extension without the script takes PDFs; the activation
/// rules must offer exactly one of the two for anything shared.
struct ShareExtensionRuleTests {
    private struct Extension {
        let name: String
        let rule: NSPredicate
        let preprocesses: Bool
    }

    private let extensions: [Extension] = {
        let plugIns = Bundle.main.builtInPlugInsURL
        let urls = (try? FileManager.default.contentsOfDirectory(at: plugIns!, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "appex" }.compactMap { url in
            let info = Bundle(url: url)?.infoDictionary
            let attributes = (info?["NSExtension"] as? [String: Any])?["NSExtensionAttributes"] as? [String: Any]
            guard let rule = attributes?["NSExtensionActivationRule"] as? String else { return nil }
            return Extension(
                name: url.deletingPathExtension().lastPathComponent, rule: NSPredicate(format: rule),
                preprocesses: attributes?["NSExtensionJavaScriptPreprocessingFile"] != nil)
        }
    }()

    private func offered(_ types: [[String]]) -> [String] {
        offered(items: [types])
    }

    /// One entry per extension item, each with its attachments' types.
    private func offered(items: [[[String]]]) -> [String] {
        let share = ["extensionItems": items.map { ["attachments": $0.map { ["registeredTypeIdentifiers": $0] }] }]
        return extensions.filter { $0.rule.evaluate(with: share) }.map(\.name)
    }

    @Test func bothExtensionsAreEmbedded() {
        #expect(extensions.map(\.name).sorted() == ["SharesheetShare", "SharesheetSharePDF"])
        #expect(extensions.first { $0.name == "SharesheetShare" }?.preprocesses == true)
        #expect(extensions.first { $0.name == "SharesheetSharePDF" }?.preprocesses == false)
    }

    @Test func webPagesGoToTheExtensionWithTheScript() {
        #expect(offered([["public.url"]]) == ["SharesheetShare"])
        #expect(offered([["public.url"], ["public.plain-text"]]) == ["SharesheetShare"])
    }

    @Test func pdfsGoToTheExtensionWithoutTheScript() {
        // Safari showing a PDF: the document and its address.
        #expect(offered([["com.adobe.pdf"], ["public.url"]]) == ["SharesheetSharePDF"])
        // A PDF from Files or Mail.
        #expect(offered([["com.adobe.pdf", "public.file-url"]]) == ["SharesheetSharePDF"])
        // The page address and the document as separate items.
        #expect(offered(items: [[["public.url"]], [["com.adobe.pdf"]]]) == ["SharesheetSharePDF"])
    }

    @Test func otherFilesStayWithTheMainExtension() {
        #expect(offered([["public.jpeg"]]) == ["SharesheetShare"])
        #expect(offered([["public.mpeg-4"]]) == ["SharesheetShare"])
    }
}
