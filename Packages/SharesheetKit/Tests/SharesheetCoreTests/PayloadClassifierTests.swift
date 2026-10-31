import Foundation
import Testing
@testable import SharesheetCore

@Test func payloadClassification() {
    #expect(PayloadClassifier.kind(registeredTypes: ["com.apple.property-list"], suggestedName: nil) == .skip)
    #expect(PayloadClassifier.kind(registeredTypes: ["public.file-url", "public.url"], suggestedName: nil) == .fileURL)
    #expect(PayloadClassifier.kind(registeredTypes: ["public.url"], suggestedName: nil) == .url)
    #expect(PayloadClassifier.kind(registeredTypes: ["public.plain-text"], suggestedName: nil) == .text)
    #expect(PayloadClassifier.kind(registeredTypes: ["public.utf8-plain-text", "public.plain-text"], suggestedName: "Note") == .text)
    // A text file is copied, never loaded into memory.
    #expect(PayloadClassifier.kind(registeredTypes: ["public.plain-text"], suggestedName: "notes.txt") == .file)
    #expect(PayloadClassifier.kind(registeredTypes: ["public.swift-source"], suggestedName: nil) == .file)
    #expect(PayloadClassifier.kind(registeredTypes: ["public.comma-separated-values-text", "public.plain-text"], suggestedName: nil) == .file)
    #expect(PayloadClassifier.kind(registeredTypes: ["public.jpeg"], suggestedName: "IMG_1") == .file)
    #expect(PayloadClassifier.kind(registeredTypes: [], suggestedName: nil) == .file)
}

@Test func textBeyondOneMegabyteIsTreatedAsFile() {
    #expect(!PayloadClassifier.isTooLargeForText(String(repeating: "a", count: 1_000_000)))
    #expect(PayloadClassifier.isTooLargeForText(String(repeating: "a", count: 1_000_001)))
}
