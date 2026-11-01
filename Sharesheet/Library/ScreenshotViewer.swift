import ImageIO
import SwiftUI
import UIKit

/// A full-page screenshot, full screen in a vertical scroll view, decoded at screen width.
struct ScreenshotViewer: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @State private var strips: [ScreenshotDecoder.Strip]?
    @State private var failed = false

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(strips ?? []) { strip in
                        Image(decorative: strip.image, scale: 1)
                            .resizable()
                            .aspectRatio(CGSize(width: strip.image.width, height: strip.image.height), contentMode: .fit)
                    }
                }
            }
            .overlay {
                if failed {
                    ContentUnavailableView("File missing", systemImage: "photo")
                } else if strips == nil {
                    ProgressView()
                }
            }
            .task(id: geometry.size.width) {
                let url = self.url
                let width = geometry.size.width * displayScale
                let decoded = await Task.detached(priority: .userInitiated) {
                    ScreenshotDecoder.strips(of: url, targetWidth: width)
                }.value
                strips = decoded
                failed = decoded == nil
            }
        }
        .background(Color(uiColor: .systemBackground))
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Label("Close", systemImage: "xmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .font(.title)
                    .symbolRenderingMode(.hierarchical)
            }
            .padding()
        }
    }
}

/// The header preview of a screenshot: its top part, decoded off the main thread. Tapping opens the viewer.
struct ScreenshotThumbnail: View {
    let relativePath: String
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    @State private var url: URL?
    @State private var image: CGImage?
    @State private var missing = false
    @State private var showsViewer = false

    private static let height: CGFloat = 260

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let image {
                    Button {
                        showsViewer = true
                    } label: {
                        Image(decorative: image, scale: displayScale)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width, height: Self.height, alignment: .top)
                            .clipped()
                    }
                    .buttonStyle(.plain)
                } else if missing {
                    ContentUnavailableView("File missing", systemImage: "photo")
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .task(id: relativePath) {
                guard let resolved = await model.attachmentURL(relativePath) else {
                    missing = true
                    return
                }
                let width = geometry.size.width * displayScale
                let height = Self.height * displayScale
                let decoded = await Task.detached(priority: .userInitiated) {
                    ScreenshotDecoder.top(of: resolved, targetWidth: width, height: height)
                }.value
                url = resolved
                image = decoded
                missing = decoded == nil
            }
        }
        .frame(height: Self.height)
        .fullScreenCover(isPresented: $showsViewer) {
            if let url { ScreenshotViewer(url: url) }
        }
    }
}

/// Decodes large PNGs with `CGImageSource` downsampling, never holding more pixels than the target width needs.
enum ScreenshotDecoder {
    struct Strip: Identifiable, @unchecked Sendable {
        let id: Int
        let image: CGImage
    }

    /// Strips stay below the GPU texture limit, which a single 40,000 px tall layer would exceed.
    private static let stripHeight = 4096

    /// The image scaled down (never up) to `targetWidth` pixels wide, cut into strips sharing one decoded bitmap.
    static func strips(of url: URL, targetWidth: CGFloat) -> [Strip]? {
        guard let image = decode(url, targetWidth: targetWidth) else { return nil }
        return stride(from: 0, to: image.height, by: stripHeight).enumerated().compactMap { index, y in
            let rect = CGRect(x: 0, y: y, width: image.width, height: min(stripHeight, image.height - y))
            return image.cropping(to: rect).map { Strip(id: index, image: $0) }
        }
    }

    /// The top `height` pixels of the image at `targetWidth`, copied into a bitmap of their own.
    static func top(of url: URL, targetWidth: CGFloat, height: CGFloat) -> CGImage? {
        guard let image = decode(url, targetWidth: targetWidth),
            let cropped = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: min(image.height, Int(height)))),
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: cropped.width, height: cropped.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        return context.makeImage()
    }

    private static func decode(_ url: URL, targetWidth: CGFloat) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard targetWidth > 0,
            let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
            width > 0, height > 0
        else { return nil }
        // The longer side bounds the thumbnail: scale it so the width lands on the target.
        let scale = min(1, targetWidth / width)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int((max(width, height) * scale).rounded(.up)),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
