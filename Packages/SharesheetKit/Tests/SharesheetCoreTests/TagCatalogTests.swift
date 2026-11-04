import Foundation
import Testing
@testable import SharesheetCore

@Suite struct TagCatalogTests {
    @Test(arguments: [
        ("rechnung", ["Rechnung"], "Rechnung"),
        ("Rechnungen", ["Rechnung"], "Rechnung"),
        ("RECHNUNG ", ["Rechnung"], "Rechnung"),
        ("Kontoauszüge", ["Kontoauszug"], "Kontoauszug"),
        ("Beiträge", ["Beitrag"], "Beitrag"),
        ("Gutschriften", ["Gutschrift"], "Gutschrift"),
        ("Beitrags-Vorschreibung", ["Beitragsvorschreibung"], "Beitragsvorschreibung"),
        ("Rechnnung", ["Rechnung"], "Rechnung"),
    ])
    func duplicatesResolveToExistingSpelling(proposed: String, existing: [String], expected: String) {
        #expect(TagCatalog.resolve(proposed, among: existing) == expected)
    }

    @Test(arguments: [
        ("Rechnungslegung", ["Rechnung"], "Rechnungslegung"),
        ("Mahnung", ["Rechnung"], "Mahnung"),
        ("Vertrag", ["Vertrag AG"], "Vertrag"),
        ("  Beitragsvorschreibung  ", [], "Beitragsvorschreibung"),
        ("Gas", ["Gast"], "Gas"),
    ])
    func distinctNamesStay(proposed: String, existing: [String], expected: String) {
        #expect(TagCatalog.resolve(proposed, among: existing) == expected)
    }

    @Test func innerWhitespaceIsCollapsed() {
        #expect(TagCatalog.resolve("Kfz   Versicherung", among: []) == "Kfz Versicherung")
    }

    @Test(arguments: ["", "   ", "!!!", String(repeating: "a", count: 41), "eine sehr lange Antwort hier"])
    func junkGivesNil(proposed: String) {
        #expect(TagCatalog.resolve(proposed, among: ["Rechnung"]) == nil)
    }
}
