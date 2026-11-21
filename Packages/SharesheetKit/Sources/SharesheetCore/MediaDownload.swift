import Foundation

/// Downloaded media files in a temporary folder, plus the post's caption. Shared by the Instagram and X loaders.
public struct MediaDownload: Equatable, Sendable {
    public var files: [URL]
    public var caption: String?

    public init(files: [URL], caption: String? = nil) {
        self.files = files
        self.caption = caption
    }
}
