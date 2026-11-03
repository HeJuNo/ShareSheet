import Foundation
import Testing
import UniformTypeIdentifiers
@testable import SharesheetCore

private let t0: Date = {
    let components = DateComponents(year: 2026, month: 10, day: 31, hour: 21, minute: 44)
    return Calendar.current.date(from: components)!
}()
private let id0 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

private func file(_ name: String, type: UTType = .jpeg) -> SharedInput {
    .file(URL(fileURLWithPath: "/tmp/src/\(name)"), contentType: type, name: name)
}

@Test func singleURLStateIsCleanedAndPreset() {
    let s = ShareRequestBuilder.initialState(for: [.url(URL(string: "https://youtu.be/x?si=abc")!, pageTitle: "Vid", selection: "quote")], existing: nil, now: t0)
    #expect(s.url?.absoluteString == "https://youtu.be/x" && s.type == .video && s.title == "Vid")
    #expect(s.highlight == "quote" && s.collection == .unsorted && s.newCollectionName == nil)
}

@Test func singleURLWithoutTitleUsesHostAndDropsBlankSelection() {
    let s = ShareRequestBuilder.initialState(
        for: [.url(URL(string: "https://example.com/a")!, pageTitle: nil, selection: "  \n ")], existing: nil, now: t0)
    #expect(s.title == "example.com" && s.type == .link && s.highlight == nil)
}

@Test func multipleFilesProposeNewCollection() {
    let s = ShareRequestBuilder.initialState(for: [file("a.jpg"), file("b.jpg")], existing: nil, now: t0) // t0 = 2026-10-31 21:44 local
    #expect(s.newCollectionName == "Share 2026-10-31 21:44" && s.collection == .root)
    #expect(s.type == .image)
}

@Test func newCollectionNameUsesInjectedTimeZone() {
    let utc = TimeZone(identifier: "UTC")!
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    let date = calendar.date(from: DateComponents(year: 2026, month: 1, day: 2, hour: 3, minute: 4))!
    let s = ShareRequestBuilder.initialState(for: [file("a.jpg"), file("b.pdf", type: .pdf)], existing: nil, now: date, timeZone: utc)
    #expect(s.newCollectionName == "Share 2026-01-02 03:04")
}

@Test func existingItemPrefillsAndOnlyChangesAreSent() {
    let existing = Item.fixture(title: "Kept", tags: ["a"], note: "n")
    let initial = ShareRequestBuilder.initialState(for: [.url(existing.url!, pageTitle: "New title", selection: nil)], existing: existing, now: t0)
    #expect(initial.title == "Kept" && initial.tags == ["a"])
    var edited = initial; edited.tags = ["a", "b"]; edited.favorite = true
    let (req, _) = ShareRequestBuilder.request(from: edited, initial: initial, inputs: [], existing: existing, id: id0, now: t0)
    #expect(req.existingItem == existing.id)
    #expect(req.edits == SheetEdits(favorite: true, addedTags: ["b"], removedTags: []))
}

@Test func reshareCarriesHighlightAndFinalStateForFallback() {
    let existing = Item.fixture(id: "Reading/Kept.md", title: "Kept", tags: ["a", "b"], note: "n")
    let input = SharedInput.url(existing.url!, pageTitle: nil, selection: "new quote")
    let initial = ShareRequestBuilder.initialState(for: [input], existing: existing, now: t0)
    #expect(initial.collection == CollectionPath(components: ["Reading"]) && initial.highlight == "new quote")
    var edited = initial
    edited.tags = ["b", "c"]; edited.collection = .unsorted; edited.title = "Renamed"
    let (req, files) = ShareRequestBuilder.request(from: edited, initial: initial, inputs: [input], existing: existing, id: id0, now: t0)
    #expect(req.edits == SheetEdits(title: "Renamed", collection: .unsorted, addedTags: ["c"], removedTags: ["a"]))
    #expect(req.entries.count == 1 && req.entries[0].highlight == "new quote" && req.entries[0].url == existing.url)
    #expect(req.collection == .unsorted && req.tags == ["b", "c"] && req.note == "n")
    #expect(files.isEmpty && req.id == id0 && req.created == t0)
}

@Test func newURLRequestCarriesDescriptionHighlightAndPreview() {
    let input = SharedInput.url(URL(string: "https://example.com/?utm_source=x")!, pageTitle: "Page", selection: "sel")
    var state = ShareRequestBuilder.initialState(for: [input], existing: nil, now: t0)
    state.description = "About"; state.note = "my note"; state.tags = ["t"]; state.favorite = true
    let preview = URL(fileURLWithPath: "/tmp/preview-src.jpg")
    let (req, files) = ShareRequestBuilder.request(
        from: state, initial: state, inputs: [input], existing: nil, id: id0, now: t0, previewImage: preview)
    #expect(req.existingItem == nil && req.edits == nil)
    #expect(req.collection == .unsorted && req.tags == ["t"] && req.note == "my note" && req.favorite)
    let entry = req.entries[0]
    #expect(entry.url?.absoluteString == "https://example.com/" && entry.title == "Page" && entry.type == .link)
    #expect(entry.description == "About" && entry.highlight == "sel" && entry.previewImageName == "preview.jpg")
    #expect(files == ["preview.jpg": preview])
}

@Test func textInputBecomesTextEntryWithFirstLineTitle() {
    let text = "\n  Line one  \nLine two"
    let input = SharedInput.text(text)
    let s = ShareRequestBuilder.initialState(for: [input], existing: nil, now: t0)
    #expect(s.type == .text && s.title == "Line one" && s.url == nil && s.collection == .unsorted)
    let (req, files) = ShareRequestBuilder.request(from: s, initial: s, inputs: [input], existing: nil, id: id0, now: t0)
    #expect(req.entries.count == 1 && req.entries[0].type == .text && req.entries[0].content == text)
    #expect(req.entries[0].title == "Line one" && files.isEmpty)
}

@Test func longTextTitleIsTruncated() {
    let s = ShareRequestBuilder.initialState(for: [.text(String(repeating: "x", count: 200))], existing: nil, now: t0)
    #expect(s.title.count == 80)
}

@Test func singleFileUsesContentTypePresetAndStem() {
    let s = ShareRequestBuilder.initialState(for: [file("Report.final.pdf", type: .pdf)], existing: nil, now: t0)
    #expect(s.type == .document && s.title == "Report.final" && s.newCollectionName == nil && s.collection == .unsorted)
}

@Test func fileEntriesReferenceInboxNames() {
    let inputs = [
        file("a.jpg"), file("a.jpg"), file("a..b.jpg"),
        file("IMG_0001", type: .heic), file("preview.jpg"), file("request.json", type: .json),
    ]
    let s = ShareRequestBuilder.initialState(for: inputs, existing: nil, now: t0)
    let (req, files) = ShareRequestBuilder.request(from: s, initial: s, inputs: inputs, existing: nil, id: id0, now: t0)
    let names = req.entries.map { $0.fileName ?? "" }
    #expect(names[0] == "a.jpg" && names[1] == "a 2.jpg")
    #expect(Set(names).count == names.count)
    #expect(names[3] == "IMG_0001.heic")
    for name in names {
        #expect(!name.isEmpty && !name.contains("/") && !name.contains(".."))
        #expect(!["request.json", "progress.json", "preview.jpg"].contains(name))
    }
    for (index, input) in inputs.enumerated() {
        guard case .file(let source, _, _, _) = input else { Issue.record("not a file"); continue }
        #expect(files[names[index]] == source)
    }
    #expect(req.entries.map(\.type) == [.image, .image, .image, .image, .image, .document])
    #expect(req.entries[0].title == "a" && req.entries[3].title == "IMG_0001")
    #expect(req.newCollectionName == "Share 2026-10-31 21:44" && req.collection == .root)
    #expect(req.existingItem == nil && req.edits == nil)
}

@Test func multiShareUsesEditedCollectionNameAndTypeOverride() {
    let inputs = [file("a.jpg"), file("b.pdf", type: .pdf)]
    let initial = ShareRequestBuilder.initialState(for: inputs, existing: nil, now: t0)
    var edited = initial
    edited.newCollectionName = "  Trip  "; edited.collection = CollectionPath(components: ["Travel"])
    let (req, _) = ShareRequestBuilder.request(from: edited, initial: initial, inputs: inputs, existing: nil, id: id0, now: t0)
    #expect(req.newCollectionName == "Trip" && req.collection == CollectionPath(components: ["Travel"]))
    #expect(req.entries.map(\.type) == [.image, .document])
    edited.type = .book; edited.newCollectionName = " "
    let (overridden, _) = ShareRequestBuilder.request(from: edited, initial: initial, inputs: inputs, existing: nil, id: id0, now: t0)
    #expect(overridden.entries.map(\.type) == [.book, .book])
    #expect(overridden.newCollectionName == "Share 2026-10-31 21:44")
}

@Test func normalizedCollapsesDuplicateLinkAttachments() {
    let url = URL(string: "https://example.com/a")!
    let tracked = URL(string: "https://example.com/a?si=xyz")!
    let deduped = ShareRequestBuilder.normalized([.url(url, pageTitle: nil, selection: nil), .url(tracked, pageTitle: nil, selection: nil)])
    #expect(deduped.inputs.count == 1)
    let withCaption = ShareRequestBuilder.normalized([.url(url, pageTitle: nil, selection: nil), .text("A title")])
    #expect(withCaption.inputs.count == 1)
    if case .url(let kept, _, _, _) = withCaption.inputs.first { #expect(kept == url) } else { Issue.record("expected url") }
    let twoLinks = ShareRequestBuilder.normalized([.url(url, pageTitle: nil, selection: nil), .url(URL(string: "https://other.org/")!, pageTitle: nil, selection: nil)])
    #expect(twoLinks.inputs.count == 2)
    #expect(ShareRequestBuilder.normalized([file("a.jpg"), file("b.jpg")]).inputs.count == 2)
    #expect(ShareRequestBuilder.normalized([file("a.jpg"), .text("caption")]).inputs.count == 2)
    #expect(ShareRequestBuilder.normalized([.text("one"), .text("two")]).inputs.count == 2)
}

@Test func normalizedTurnsAccompanyingTextIntoTitleOrNote() {
    let url = URL(string: "https://example.com/a")!
    let titled = ShareRequestBuilder.normalized([.url(url, pageTitle: nil, selection: nil), .text("  A caption ")])
    #expect(titled.inputs.count == 1 && titled.note == nil)
    if case .url(_, let pageTitle, _, _) = titled.inputs.first { #expect(pageTitle == "A caption") } else { Issue.record("expected url") }
    let noted = ShareRequestBuilder.normalized([.url(url, pageTitle: "Page", selection: nil), .text("Look at this"), .text(url.absoluteString)])
    #expect(noted.inputs.count == 1 && noted.note == "Look at this")
    let state = ShareRequestBuilder.initialState(for: titled.inputs, existing: nil, now: t0)
    #expect(state.title == "A caption")
}

@Test func urlDescriptionPrefillsState() {
    let input = SharedInput.url(URL(string: "https://example.com/a")!, pageTitle: "P", selection: nil, description: "  About it ")
    let s = ShareRequestBuilder.initialState(for: [input], existing: nil, now: t0)
    #expect(s.description == "About it")
    let (req, _) = ShareRequestBuilder.request(from: s, initial: s, inputs: [input], existing: nil, id: id0, now: t0)
    #expect(req.entries[0].description == "About it")
    let multi = ShareRequestBuilder.initialState(for: [input, file("a.jpg")], existing: nil, now: t0)
    let (multiReq, _) = ShareRequestBuilder.request(from: multi, initial: multi, inputs: [input, file("a.jpg")], existing: nil, id: id0, now: t0)
    #expect(multiReq.entries[0].description == "About it")
}

@Test func normalizedDropsBrowserOnlyAddresses() {
    let blob = SharedInput.url(URL(string: "blob:https://example.com/53946572-b1")!, pageTitle: nil, selection: nil)
    let result = ShareRequestBuilder.normalized([file("Rechnung.pdf", type: .pdf), blob])
    #expect(result.inputs.count == 1)
    guard case .file(_, _, let name, let source) = result.inputs.first else { Issue.record("not a file"); return }
    #expect(name == "Rechnung.pdf" && source == nil)
}

@Test func singleFileWithOneLinkKeepsTheLinkAsItsSource() {
    let link = SharedInput.url(URL(string: "https://example.com/docs/sample.pdf?utm_source=x")!, pageTitle: nil, selection: nil)
    let inputs = ShareRequestBuilder.normalized([file("sample.pdf", type: .pdf), link]).inputs
    #expect(inputs.count == 1)
    guard case .file(_, _, _, let source) = inputs.first else { Issue.record("not a file"); return }
    #expect(source?.absoluteString == "https://example.com/docs/sample.pdf")

    let s = ShareRequestBuilder.initialState(for: inputs, existing: nil, now: t0)
    #expect(s.type == .document && s.title == "sample" && s.url == source)
    let (req, files) = ShareRequestBuilder.request(from: s, initial: s, inputs: inputs, existing: nil, id: id0, now: t0)
    #expect(req.entries.count == 1 && req.entries[0].fileName == "sample.pdf" && req.entries[0].url == source)
    #expect(files["sample.pdf"] != nil)
}

@Test func filesWithSeveralLinksStaySeparate() {
    let a = SharedInput.url(URL(string: "https://example.com/a")!, pageTitle: nil, selection: nil)
    let b = SharedInput.url(URL(string: "https://example.com/b")!, pageTitle: nil, selection: nil)
    #expect(ShareRequestBuilder.normalized([file("a.jpg"), a, b]).inputs.count == 3)
    #expect(ShareRequestBuilder.normalized([file("a.jpg"), file("b.jpg"), a]).inputs.count == 3)
}
