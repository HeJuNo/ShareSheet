import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import SharesheetCore

/// Draws `text` as black glyphs at `x`/`y` (baseline) into `context`.
private func draw(_ text: String, in context: CGContext, fontSize: CGFloat, x: CGFloat, y: CGFloat) {
    let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, context)
}

/// A bitmap of black text on white, large enough for reliable recognition.
private func textBitmap(_ text: String, fontSize: CGFloat = 48) throws -> CGImage {
    let width = 900, height = 200
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    draw(text, in: context, fontSize: fontSize, x: 40, y: 70)
    return try #require(context.makeImage())
}

private func writePNG(_ image: CGImage, to url: URL) throws {
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
}

private func pdfContext(at url: URL, password: String? = nil) throws -> CGContext {
    var info: [CFString: Any] = [:]
    if let password {
        info[kCGPDFContextUserPassword] = password
        info[kCGPDFContextOwnerPassword] = password
    }
    var box = CGRect(x: 0, y: 0, width: 612, height: 200)
    return try #require(CGContext(url as CFURL, mediaBox: &box, info as CFDictionary))
}

private func writeTextPDF(_ text: String, to url: URL, password: String? = nil) throws {
    let context = try pdfContext(at: url, password: password)
    context.beginPDFPage(nil)
    draw(text, in: context, fontSize: 24, x: 40, y: 100)
    context.endPDFPage()
    context.closePDF()
}

/// A PDF whose pages hold only a bitmap of the given text, so there is no text layer.
private func writeScannedPDF(_ pageTexts: [String], to url: URL) throws {
    let context = try pdfContext(at: url)
    for text in pageTexts {
        let image = try textBitmap(text)
        context.beginPDFPage(nil)
        context.draw(image, in: CGRect(x: 0, y: 0, width: 612, height: 200))
        context.endPDFPage()
    }
    context.closePDF()
}

@Suite struct DocumentTextExtractorTests {
    @Test func textPDFReturnsItsText() async throws {
        let file = try makeTempDirectory().appending(path: "text.pdf")
        try writeTextPDF("Kontoauszug Oktober fuer das Konto 4711", to: file)
        let text = await DocumentTextExtractor.text(from: file, contentType: .pdf)
        #expect(text.contains("Kontoauszug"))
    }

    @Test func scannedPDFIsReadByOCR() async throws {
        let file = try makeTempDirectory().appending(path: "scan.pdf")
        try writeScannedPDF(["Rechnung"], to: file)
        let text = await DocumentTextExtractor.text(from: file, contentType: .pdf)
        #expect(text.contains("Rechnung"))
    }

    @Test func imageIsReadByOCR() async throws {
        let file = try makeTempDirectory().appending(path: "scan.png")
        try writePNG(try textBitmap("Rechnung"), to: file)
        let text = await DocumentTextExtractor.text(from: file, contentType: .png)
        #expect(text.contains("Rechnung"))
    }

    @Test func plainTextHandlesUTF8AndLatin1() async throws {
        let directory = try makeTempDirectory()
        let utf8 = directory.appending(path: "utf8.txt")
        try Data("Grüße aus Köln".utf8).write(to: utf8)
        let latin1 = directory.appending(path: "latin1.txt")
        try #require("Grüße aus Köln".data(using: .isoLatin1)).write(to: latin1)
        #expect(await DocumentTextExtractor.text(from: utf8, contentType: .plainText) == "Grüße aus Köln")
        #expect(await DocumentTextExtractor.text(from: latin1, contentType: .plainText) == "Grüße aus Köln")
    }

    @Test func lockedOrCorruptOrUnsupportedGivesEmpty() async throws {
        let directory = try makeTempDirectory()
        let locked = directory.appending(path: "locked.pdf")
        try writeTextPDF("Geheim", to: locked, password: "secret")
        #expect(await DocumentTextExtractor.text(from: locked, contentType: .pdf) == "")

        let corrupt = directory.appending(path: "corrupt.pdf")
        try Data((0..<2048).map { _ in UInt8.random(in: 0...255) }).write(to: corrupt)
        #expect(await DocumentTextExtractor.text(from: corrupt, contentType: .pdf) == "")

        let zip = directory.appending(path: "archive.zip")
        try Data("PK\u{3}\u{4}not really a zip".utf8).write(to: zip)
        #expect(await DocumentTextExtractor.text(from: zip, contentType: .zip) == "")

        let missing = directory.appending(path: "missing.pdf")
        #expect(await DocumentTextExtractor.text(from: missing, contentType: .pdf) == "")
    }

    @Test func longTextIsCapped() async throws {
        let directory = try makeTempDirectory()
        let file = directory.appending(path: "long.txt")
        try Data(String(repeating: "a", count: 300_000).utf8).write(to: file)
        let text = await DocumentTextExtractor.text(from: file, contentType: .plainText)
        #expect(text.count == DocumentTextExtractor.maxCharacters)
    }

    @Test func scannedPDFOnlyOCRsTheFirstPages() async throws {
        let file = try makeTempDirectory().appending(path: "long-scan.pdf")
        var pages = (1...40).map { _ in "Rechnung" }
        pages[0] = "Alpha"
        pages[39] = "Omega"
        try writeScannedPDF(pages, to: file)
        let text = await DocumentTextExtractor.text(from: file, contentType: .pdf)
        #expect(text.contains("Alpha"))
        #expect(!text.contains("Omega"))
    }

    @Test func cancellingStopsOCRWithinAPage() async throws {
        let file = try makeTempDirectory().appending(path: "scan30.pdf")
        try writeScannedPDF((1..<31).map { _ in "Rechnung" }, to: file)
        let start = ContinuousClock.now
        let task = Task { await DocumentTextExtractor.text(from: file, contentType: .pdf) }
        try await Task.sleep(for: .milliseconds(700))
        task.cancel()
        let text = await task.value
        let elapsed = ContinuousClock.now - start
        let pages = text.components(separatedBy: "Rechnung").count - 1
        // 30 pages of accurate OCR take far longer than this; a cancelled run ends after the page in flight.
        #expect(elapsed < .seconds(6), "took \(elapsed)")
        #expect(pages < 30, "read \(pages) pages")
    }
}
