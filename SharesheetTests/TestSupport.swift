import CoreGraphics
import CoreText
import Foundation
import Testing
import SharesheetCore

/// A fetcher for tests that must not reach the network.
struct NoFetch: ResourceFetching {
    func fetch(_ url: URL) async throws -> (data: Data, mimeType: String?) { throw URLError(.badURL) }
}

/// A one-page PDF with `lines` of text, written to `dir`.
func makeTestPDF(
    in dir: URL, name: String = "doc-\(UUID().uuidString).pdf",
    lines: [String] = ["Rechnung Nummer 4711 Tischlerei Eichenholz", "Hobelbank Leimzwingen Eichenholz Hobelbank"]
) throws -> URL {
    let url = dir.appending(path: name)
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
    context.beginPDFPage(nil)
    for (row, line) in lines.enumerated() {
        let string = NSAttributedString(
            string: line, attributes: [kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("Helvetica" as CFString, 14, nil)])
        context.textPosition = CGPoint(x: 40, y: 740 - Double(row) * 24)
        CTLineDraw(CTLineCreateWithAttributedString(string), context)
    }
    context.endPDFPage()
    context.closePDF()
    return url
}
