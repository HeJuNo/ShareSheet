import Foundation
import UniformTypeIdentifiers

public enum ItemType: String, Codable, CaseIterable, Sendable {
    case link, article, book, document, image, audio, video, text
}

public enum CaptureState: String, Codable, Sendable {
    case pending, done, failed
}

extension ItemType {
    private static let videoHosts = ["youtube.com", "youtu.be", "vimeo.com"]

    /// `.video` for YouTube and Vimeo links, `.link` otherwise.
    public static func preset(for url: URL) -> ItemType {
        guard let host = url.host?.lowercased() else { return .link }
        let isVideo = videoHosts.contains { host == $0 || host.hasSuffix("." + $0) }
        return isVideo ? .video : .link
    }

    /// The item type for a shared file of the given content type.
    public static func preset(forContentType type: UTType) -> ItemType {
        if type.conforms(to: .pdf) { return .document }
        if type.conforms(to: .plainText) { return .text }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) { return .video }
        return .document
    }

    public var label: LocalizedStringResource {
        switch self {
        case .link: "Link"
        case .article: "Article"
        case .book: "Book"
        case .document: "Document"
        case .image: "Image"
        case .audio: "Audio"
        case .video: "Video"
        case .text: "Text"
        }
    }
}
