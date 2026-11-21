import Testing
@testable import SharesheetCore

struct MediaKindTests {
    @Test(arguments: [
        ("Unsorted/1.jpg", MediaKind.image),
        ("a.JPEG", .image),
        ("cover.png", .image),
        ("clip.mp4", .video),
        ("clip.MOV", .video),
        ("preview.mp3", .audio),
        ("voice.m4a", .audio),
        ("sound.wav", .audio),
        ("notes.pdf", .other),
        ("no-extension", .other),
    ])
    func readsTheExtension(path: String, kind: MediaKind) {
        #expect(MediaKind(path: path) == kind)
    }
}
