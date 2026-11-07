import Foundation
import LinkPresentation
import SharesheetCore
import UIKit
import UniformTypeIdentifiers

struct LinkPreview: Sendable {
    var title: String?
    /// A small JPEG written into the share's temp directory.
    var imageURL: URL?
}

/// Fetches title and preview image for a link through LinkPresentation, giving up after 5 s.
/// Callers run it alongside the form; Save never waits for it.
@MainActor
final class LinkPreviewLoader {
    private static let timeout: TimeInterval = 5
    private nonisolated static let maxPixelSize = 600
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

    /// Loads the preview image and writes a JPEG of at most `maxPixelSize` pixels, decoded straight at that size
    /// so a large image never reaches full-size memory in the extension; nil on any failure.
    nonisolated private static func writeImage(
        _ provider: NSItemProvider, to destination: URL, completion: @escaping @Sendable (URL?) -> Void
    ) {
        let write: @Sendable (Data?) -> Void = { data in
            guard let data else { return completion(nil) }
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
                completion(destination)
            } catch {
                completion(nil)
            }
        }
        // Data-backed providers are written to a temporary file too; it only lives until this handler returns.
        _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
            write(url.flatMap { ImageDownsampler.jpegData(fromFileAt: $0, maxPixelSize: maxPixelSize) })
        }
    }
}
