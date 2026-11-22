import AVKit
import Combine
import QuickLookThumbnailing
import SharesheetCore
import SwiftUI

/// The downloaded images, videos and clips of a post, in post order; tapping opens the swipeable viewer.
struct MediaStrip: View {
    let paths: [String]
    let open: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Media")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    let cover = paths.first { MediaKind(path: $0) == .image }
                    ForEach(paths.indices, id: \.self) { index in
                        MediaThumbnail(
                            relativePath: paths[index], coverPath: cover,
                            position: index, count: paths.count) { open(index) }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }
}

private struct MediaThumbnail: View {
    let relativePath: String
    /// An audio file shows the post's cover instead of Quick Look's white audio icon.
    let coverPath: String?
    let position: Int
    let count: Int
    let open: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    @State private var url: URL?
    @State private var thumbnail: UIImage?

    private static let size: CGFloat = 140

    private var kind: MediaKind { MediaKind(path: relativePath) }

    private var kindName: String {
        switch kind {
        case .image: "image"
        case .video: "video"
        case .audio: "audio clip"
        case .other: "file"
        }
    }

    var body: some View {
        Button {
            open()
        } label: {
            ZStack {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.secondary.opacity(0.15)
                }
                if kind == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.white)
                        .shadow(radius: 3)
                } else if kind == .audio {
                    Image(systemName: "music.note")
                        .font(.headline)
                        .padding(6)
                        .background(.black.opacity(0.55), in: Circle())
                        .foregroundStyle(.white)
                }
            }
            .frame(width: Self.size, height: Self.size)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
        .accessibilityLabel(Text("Media \(position + 1) of \(count), \(kindName)"))
        .accessibilityHint(Text((relativePath as NSString).lastPathComponent))
        .task(id: relativePath) {
            let maxPixel = Int(Self.size * displayScale)
            // iCloud may still be downloading: a short wait and a retry leaves the download running, instead
            // of showing a blank tile forever when the first request times out.
            for attempt in 0..<6 {
                guard !Task.isCancelled else { return }
                guard let resolved = await model.attachmentURL(relativePath, timeout: .seconds(15)) else {
                    if attempt < 5 { try? await Task.sleep(for: .seconds(2)) }
                    continue
                }
                url = resolved
                if kind == .audio {
                    if let coverPath, coverPath != relativePath,
                       let cover = await model.attachmentURL(coverPath, timeout: .seconds(15)) {
                        thumbnail = await MediaThumbnailLoader.image(for: .image, url: cover, maxPixel: maxPixel)
                    }
                    return  // without a cover the grey tile and the music note are the preview
                }
                thumbnail = await MediaThumbnailLoader.image(for: kind, url: resolved, maxPixel: maxPixel)
                return  // a readable file that yields no image will not improve on a retry
            }
        }
    }
}

/// Renders the tile image from the file itself: ImageIO for pictures, the first frame for videos, Quick Look
/// only for file types that have no direct decoder. Quick Look alone failed for some files and left blank tiles.
private enum MediaThumbnailLoader {
    static func image(for kind: MediaKind, url: URL, maxPixel: Int) async -> UIImage? {
        switch kind {
        case .image:
            let data = await Task.detached(priority: .utility) {
                ImageDownsampler.jpegData(fromFileAt: url, maxPixelSize: maxPixel, quality: 0.85)
            }.value
            if let data, let image = UIImage(data: data) { return image }
            return await quickLook(url, maxPixel: maxPixel)
        case .video:
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
            if let frame = try? await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)) {
                return UIImage(cgImage: frame.image)
            }
            return await quickLook(url, maxPixel: maxPixel)
        case .audio, .other:
            return await quickLook(url, maxPixel: maxPixel)
        }
    }

    private static func quickLook(_ url: URL, maxPixel: Int) async -> UIImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: maxPixel, height: maxPixel), scale: 1,
            representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage
    }
}

/// Full-screen pager over the post's media; swipe left/right for the next/previous item.
struct MediaPreviewView: View {
    let paths: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Int

    init(paths: [String], startIndex: Int) {
        self.paths = paths
        _selection = State(initialValue: startIndex)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // A plain paging ScrollView instead of TabView: TabView measured the pages differently after a
            // swipe, so a landscape page sat ~130 pt off-screen. Every page here has the same explicit width.
            GeometryReader { proxy in
                ScrollViewReader { scroller in
                    ScrollView(.horizontal, showsIndicators: false) {
                        // A plain HStack keeps every page alive. The page at distance 1 is prefetched, so the
                        // next/previous file is already decoded when it scrolls in; a lazy stack dropped that
                        // state and showed a spinner (visible flicker) on every swipe.
                        HStack(spacing: 0) {
                            ForEach(paths.indices, id: \.self) { index in
                                MediaPreviewPage(
                                    relativePath: paths[index], position: index, count: paths.count,
                                    isSelected: selection == index, isNear: abs(index - selection) <= 1)
                                    .frame(width: proxy.size.width, height: proxy.size.height)
                                    .id(index)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollPosition(id: Binding(
                        get: { selection },
                        set: { if let page = $0 { selection = page } }))
                    .onAppear { scroller.scrollTo(selection, anchor: .center) }
                    .onChange(of: proxy.size) { _, _ in scroller.scrollTo(selection, anchor: .center) }
                }
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.55), in: Circle())
                    .foregroundStyle(.white)
            }
            .padding(12)
            .accessibilityLabel(Text("Close"))
        }
        .overlay(alignment: .bottom) {
            if paths.count > 1 {
                HStack(spacing: 8) {
                    ForEach(paths.indices, id: \.self) { index in
                        Circle()
                            .fill(index == selection ? .white : .white.opacity(0.35))
                            .frame(width: 8, height: 8)
                    }
                }
                .padding(.bottom, 10)
                .accessibilityHidden(true)
            }
        }
        .preferredColorScheme(.dark)
        .allowsLandscape()
        // Videos and Spotify previews are media playback: the playback category lets them be heard even with
        // the ring/silent switch on. Without it AVPlayer uses the ambient category and stays silent there.
        .onAppear {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback)
            try? session.setActive(true)
        }
        .onDisappear {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

private struct MediaPreviewPage: View {
    let relativePath: String
    let position: Int
    let count: Int
    let isSelected: Bool
    /// Selected page or one of its neighbours: load and keep the image/player ready before it scrolls in.
    let isNear: Bool
    @Environment(AppModel.self) private var model
    @State private var url: URL?
    @State private var resolved = false
    @State private var player: AVPlayer?
    @State private var image: UIImage?
    @State private var missing = false

    /// Enough pixels for a phone screen at 3x, however large the original photo is.
    private static let maxPixelSize = 3000

    private var kind: MediaKind { MediaKind(path: relativePath) }

    var body: some View {
        Group {
            switch kind {
            case .audio:
                if let url {
                    AudioPreviewPage(url: url, isSelected: isSelected)
                } else if missing {
                    missingView
                } else {
                    spinner
                }
            case .video:
                if let player {
                    VideoPlayer(player: player)
                        .accessibilityLabel(Text("Video \(position + 1) of \(count)"))
                } else if missing {
                    missingView
                } else {
                    spinner
                }
            default:
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel(Text("Media \(position + 1) of \(count)"))
                } else if missing {
                    missingView
                } else {
                    spinner
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: isNear) {
            guard isNear else {
                // Pages two or more away release their player and decoded image; the selected page and both
                // neighbours stay ready, so a swipe never uncovers a blank page.
                player?.pause()
                player = nil
                image = nil
                return
            }
            if !resolved {
                url = await model.attachmentURL(relativePath)
                resolved = true
                missing = url == nil
            }
            guard let url else {
                missing = true
                return
            }
            switch kind {
            case .video:
                if player == nil { player = AVPlayer(url: url) }
            case .image:
                if image == nil {
                    let pixelSize = Self.maxPixelSize
                    let data = await Task.detached(priority: .userInitiated) {
                        ImageDownsampler.jpegData(fromFileAt: url, maxPixelSize: pixelSize, quality: 0.9)
                    }.value
                    guard !Task.isCancelled else { return }
                    image = data.flatMap(UIImage.init(data:))
                    missing = image == nil
                }
            default:
                break
            }
        }
        .onChange(of: isSelected) { _, selected in if !selected { player?.pause() } }
        .onDisappear { player?.pause() }
    }

    private var missingView: some View {
        ContentUnavailableView("File missing", systemImage: "photo")
    }

    private var spinner: some View {
        ProgressView().tint(.white)
    }
}

/// An audio clip gets its own transport: a black video page would show no controls.
private struct AudioPreviewPage: View {
    let url: URL
    let isSelected: Bool
    @State private var player: AVPlayer?
    @State private var isPlaying = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "music.note")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Button {
                guard let player else { return }
                if isPlaying { player.pause() } else { player.play() }
                isPlaying.toggle()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.white)
            }
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: isSelected) {
            guard isSelected else {
                player?.pause()
                player = nil
                isPlaying = false
                return
            }
            if player == nil { player = AVPlayer(url: url) }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
            guard (note.object as? AVPlayerItem) === player?.currentItem else { return }
            isPlaying = false
            player?.seek(to: .zero)
        }
        .onDisappear { player?.pause() }
    }
}
