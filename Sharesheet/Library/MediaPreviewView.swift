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
            url = await model.attachmentURL(relativePath)
            let source = if kind == .audio, let coverPath, coverPath != relativePath {
                await model.attachmentURL(coverPath)
            } else {
                url
            }
            guard let source else { return }
            let request = QLThumbnailGenerator.Request(
                fileAt: source, size: CGSize(width: Self.size, height: Self.size), scale: displayScale,
                representationTypes: .thumbnail)
            thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage
        }
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
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            TabView(selection: $selection) {
                ForEach(paths.indices, id: \.self) { index in
                    MediaPreviewPage(
                        relativePath: paths[index], position: index, count: paths.count,
                        isSelected: selection == index)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: paths.count > 1 ? .always : .never))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .ignoresSafeArea()
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
        .preferredColorScheme(.dark)
        .allowsLandscape()
    }
}

private struct MediaPreviewPage: View {
    let relativePath: String
    let position: Int
    let count: Int
    let isSelected: Bool
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
        .task(id: isSelected) {
            guard isSelected else {
                // Leaving a page releases its player and decoded image; the pager keeps every page alive.
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
                    image = data.flatMap(UIImage.init(data:))
                    missing = image == nil
                }
            default:
                break
            }
        }
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
