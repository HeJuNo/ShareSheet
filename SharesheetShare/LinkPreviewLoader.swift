import Foundation
import LinkPresentation
import SharesheetCore
import UIKit

struct LinkPreview: Sendable {
    var title: String?
    /// LinkPresentation exposes no public description, so this stays nil unless that changes.
    var description: String?
    /// A small JPEG written into the share's temp directory.
    var imageURL: URL?
}

/// Fetches title and preview image for a link through LinkPresentation, giving up after 5 s.
/// Callers run it alongside the form; Save never waits for it.
@MainActor
final class LinkPreviewLoader {
    private static let timeout: TimeInterval = 5
    private nonisolated static let maxPixelSize: CGFloat = 600
    private var provider: LPMetadataProvider?

    func load(_ url: URL, into directory: URL) async -> LinkPreview? {
        let provider = LPMetadataProvider()
        provider.timeout = Self.timeout
        self.provider = provider
        defer { self.provider = nil }
        let destination = directory.appending(path: ShareRequestBuilder.previewImageName)
        return await withCheckedContinuation { continuation in
            provider.startFetchingMetadata(for: url) { metadata, _ in
                guard let metadata else { return continuation.resume(returning: nil) }
                let title = metadata.title
                guard let imageProvider = metadata.imageProvider else {
                    return continuation.resume(returning: LinkPreview(title: title))
                }
                Self.writeImage(imageProvider, to: destination) { imageURL in
                    continuation.resume(returning: LinkPreview(title: title, imageURL: imageURL))
                }
            }
        }
    }

    func cancel() {
        provider?.cancel()
    }

    /// Loads the preview image, scales it down and writes it as JPEG; nil on any failure.
    nonisolated private static func writeImage(
        _ provider: NSItemProvider, to destination: URL, completion: @escaping @Sendable (URL?) -> Void
    ) {
        _ = provider.loadObject(ofClass: UIImage.self) { object, _ in
            guard let image = object as? UIImage else { return completion(nil) }
            let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
            let factor = min(1, maxPixelSize / max(pixels.width, pixels.height, 1))
            let size = CGSize(width: pixels.width * factor, height: pixels.height * factor)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            guard let data = resized.jpegData(compressionQuality: 0.7) else { return completion(nil) }
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
                completion(destination)
            } catch {
                completion(nil)
            }
        }
    }
}
