import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

/// Reads the plain text out of a document file: the text layer of a PDF, OCR for scanned pages and images,
/// or the characters of a text file. Everything is local; nothing leaves the device.
public enum DocumentTextExtractor {
    /// Upper bound for the returned text, so a huge file cannot flood the analysis.
    public static let maxCharacters = 200_000
    /// At most this many PDF pages are run through OCR; text-layer pages do not count.
    public static let maxOCRPages = 30

    /// A PDF page with fewer characters than this is treated as a scan and read by OCR.
    private static let minimumTextLayerCharacters = 20

    /// The text of the file, or `""` when it is unreadable, locked or of an unsupported type. Never throws.
    /// OCR and PDF rendering run off the calling actor.
    public static func text(from url: URL, contentType: UTType) async -> String {
        await Task.detached(priority: .userInitiated) {
            extract(from: url, contentType: contentType)
        }.value
    }

    private static func extract(from url: URL, contentType: UTType) -> String {
        let raw: String
        if contentType.conforms(to: .pdf) {
            raw = pdfText(at: url)
        } else if contentType.conforms(to: .image) {
            raw = imageText(at: url)
        } else if contentType.conforms(to: .plainText) {
            raw = plainText(at: url)
        } else {
            raw = ""
        }
        return String(raw.prefix(maxCharacters))
    }

    // MARK: Plain text

    private static func plainText(at url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    // MARK: PDF

    private static func pdfText(at url: URL) -> String {
        guard let document = PDFDocument(url: url), !document.isLocked else { return "" }
        var pages: [String] = []
        var ocrPages = 0
        var length = 0
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            var text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.count < minimumTextLayerCharacters, ocrPages < maxOCRPages {
                ocrPages += 1
                if let image = render(page) {
                    let recognized = recognizeText(in: image)
                    if recognized.count > text.count { text = recognized }
                }
            }
            if !text.isEmpty {
                pages.append(text)
                length += text.count + 1
            }
            if length >= maxCharacters { break }
        }
        return pages.joined(separator: "\n")
    }

    /// Renders a page at 2x onto white, capped so a very large page cannot exhaust memory.
    private static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(2, 4096 / max(bounds.width, bounds.height))
        let width = Int((bounds.width * scale).rounded(.up))
        let height = Int((bounds.height * scale).rounded(.up))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: context)
        return context.makeImage()
    }

    // MARK: Images and OCR

    private static func imageText(at url: URL) -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return "" }
        return recognizeText(in: image)
    }

    private static func recognizeText(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["de-DE", "en-US"]
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return "" }
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
