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
        // A system bar keeps the close button legible on any page and the page from running under it.
        NavigationStack {
            content
                .navigationBarTitleDisplayMode(.inline)
                .allowsLandscape()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            dismiss()
                        } label: {
                            Label("Close", systemImage: "xmark")
                        }
                    }
                }
        }
    }

    private var content: some View {
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
                let path = relativePath
                let width = Int(geometry.size.width * displayScale)
                let height = Int(Self.height * displayScale)
                let decoded = await Task.detached(priority: .userInitiated) {
                    ScreenshotDecoder.thumbnail(of: resolved, key: path, width: width, height: height)
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

    /// NSCache is documented thread-safe.
    nonisolated(unsafe) private static let thumbnails: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 64
        return cache
    }()

    /// The top `height` pixels of the image at (at most) `width` pixels wide, cached by `key` and width.
    /// The full image is decoded once, without caching, and released before this returns.
    static func thumbnail(of url: URL, key: String, width: Int, height: Int) -> CGImage? {
        let cacheKey = "\(width)|\(key)" as NSString
        if let cached = thumbnails.object(forKey: cacheKey) { return cached }
        guard let image = autoreleasepool(invoking: { top(of: url, width: width, height: height) }) else { return nil }
        thumbnails.setObject(image, forKey: cacheKey)
        return image
    }

    private static func top(of url: URL, width: Int, height: Int) -> CGImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard width > 0, height > 0,
            let source = CGImageSourceCreateWithURL(url as CFURL, options),
            let full = CGImageSourceCreateImageAtIndex(source, 0, options), full.width > 0
        else { return nil }
        let outputWidth = min(width, full.width)
        let scale = Double(outputWidth) / Double(full.width)
        let sourceHeight = min(full.height, Int((Double(height) / scale).rounded(.up)))
        let outputHeight = max(1, Int((Double(sourceHeight) * scale).rounded()))
        guard let top = full.cropping(to: CGRect(x: 0, y: 0, width: full.width, height: sourceHeight)),
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: outputWidth, height: outputHeight, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(top, in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
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
