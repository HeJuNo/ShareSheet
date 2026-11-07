import SharesheetCore
import SwiftUI

public struct ItemTypeIcon: View {
    private let type: ItemType

    public init(_ type: ItemType) {
        self.type = type
    }

    public var body: some View {
        Image(systemName: Self.symbolName(type))
    }

    static func symbolName(_ type: ItemType) -> String {
        switch type {
        case .link: "link"
        case .article: "doc.richtext"
        case .book: "book"
        case .document: "doc"
        case .image: "photo"
        case .audio: "waveform"
        case .video: "play.rectangle"
        case .text: "text.alignleft"
        }
    }
}
