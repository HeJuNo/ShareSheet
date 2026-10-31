import Foundation
import Testing
import UniformTypeIdentifiers
@testable import SharesheetCore

@Test func stripsTrackingParameters() {
    #expect(URLCleaner.clean(URL(string: "https://pamba.app/?twclid=28bq4q&utm_source=x&id=7")!).absoluteString == "https://pamba.app/?id=7")
    #expect(URLCleaner.clean(URL(string: "https://a.b/p?UTM_Medium=1")!).absoluteString == "https://a.b/p")
    #expect(URLCleaner.clean(URL(string: "https://a.b/p#frag")!).absoluteString == "https://a.b/p#frag")
}
@Test func presetsTypes() {
    #expect(ItemType.preset(for: URL(string: "https://youtu.be/abc")!) == .video)
    #expect(ItemType.preset(for: URL(string: "https://github.com/x")!) == .link)
    #expect(ItemType.preset(forContentType: .jpeg) == .image)
    #expect(ItemType.preset(forContentType: .pdf) == .document)
    #expect(ItemType.preset(forContentType: .mpeg4Movie) == .video)
    #expect(ItemType.preset(forContentType: .mp3) == .audio)
    #expect(ItemType.preset(forContentType: .plainText) == .text)
}
@Test func fileNamerHandlesHostileTitles() {
    #expect(FileNamer.sanitize("a/b:c\nd") == "a-b-c d")
    #expect(FileNamer.sanitize(String(repeating: "x", count: 300)).count == 80)
    #expect(FileNamer.sanitize("AI无法逆向你的项目！🚀") == "AI无法逆向你的项目！🚀")
    #expect(FileNamer.sanitize("...") == "Untitled")
    #expect(FileNamer.sanitize(".hidden") == "hidden")
    #expect(FileNamer.uniqueName(base: "Foo", ext: "md", existing: ["Foo.md", "Foo 2.md"]) == "Foo 3.md")
    #expect(FileNamer.uniqueName(base: "Foo", ext: "md", existing: ["foo.md"]) == "Foo 2.md") // case-insensitive FS
}
@Test func attachmentNameIsSluggedAndUnique() {
    let date = ISO8601DateFormatter().date(from: "2026-10-31T12:00:00Z")!
    #expect(FileNamer.attachmentName(base: "Bastion Router", date: date, ext: "png", existing: []) == "bastion-router-2026-10-31.png")
    #expect(FileNamer.attachmentName(base: "Bastion Router", date: date, ext: "png", existing: ["bastion-router-2026-10-31.png"]) == "bastion-router-2026-10-31-2.png")
}
