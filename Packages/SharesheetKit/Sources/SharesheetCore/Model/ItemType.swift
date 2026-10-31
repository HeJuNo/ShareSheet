public enum ItemType: String, Codable, CaseIterable, Sendable {
    case link, article, book, document, image, audio, video, text
}

public enum CaptureState: String, Codable, Sendable {
    case pending, done, failed
}
