import Foundation

/// What a media file is, from its path extension: the viewer picks its presentation from it.
public enum MediaKind: Equatable, Sendable {
    case image, video, audio, other

    public init(path: String) {
        switch (path as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic", "webp", "gif": self = .image
        case "mp4", "mov", "m4v": self = .video
        case "mp3", "m4a", "aac", "wav", "caf": self = .audio
        default: self = .other
        }
    }
}
