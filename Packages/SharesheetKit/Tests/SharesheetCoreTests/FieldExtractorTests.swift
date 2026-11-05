import Foundation
import Testing
@testable import SharesheetCore

@Suite struct FieldExtractorTests {
    private let vienna = TimeZone(identifier: "Europe/Vienna")!
    private let invoice = """
        Rechnungsnummer 4015P0002324129
        Rechnungsdatum
        2026/02/22
        Gesamtbetrag (EUR)   4.77
        Einheit kWh
        """

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = vienna
        return calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    @Test func theInvoiceTextGivesDateAndAmount() {
        #expect(FieldExtractor.value(in: invoice, pattern: "Rechnungsdatum {Datum}", timeZone: vienna) == .date(date(2026, 2, 22)))
        #expect(FieldExtractor.value(in: invoice, pattern: "Gesamtbetrag (EUR) {Zahl}") == .number(4.77))
        #expect(FieldExtractor.value(in: invoice, pattern: "Einheit {Text}") == .text("kWh"))
    }

    @Test func numbersReadCommaDotAndThousands() {
        #expect(FieldExtractor.number("4,77") == 4.77)
        #expect(FieldExtractor.number("1.234,56") == 1234.56)
        #expect(FieldExtractor.number("12.8973") == 12.8973)
        #expect(FieldExtractor.number("3") == 3)
        #expect(FieldExtractor.number("4.77.") == 4.77)
    }

    @Test func anAmbiguousThreeDigitGroupIsNotGuessed() {
        #expect(FieldExtractor.number("1.234") == nil)
        #expect(FieldExtractor.value(in: "Summe 1.234 EUR", pattern: "Summe {Zahl}") == nil)
    }

    @Test func noMatchOrAnInvalidPatternGivesNil() {
        #expect(FieldExtractor.value(in: invoice, pattern: "Betrag {Zahl}") == nil)
        #expect(FieldExtractor.value(in: invoice, pattern: "Rechnungsdatum {Zahl} {Zahl}") == nil)
        #expect(!FieldExtractor.isValid(pattern: "Gesamtbetrag"))
        #expect(!FieldExtractor.isValid(pattern: "{Zahl} {Datum}"))
        #expect(FieldExtractor.isValid(pattern: "x {zahl}"))
    }

    @Test func aTextValueEndsAtTheLineEnd() {
        #expect(FieldExtractor.value(in: "Kunde: Max Muster\nOrt Wien", pattern: "Kunde: {Text}") == .text("Max Muster"))
    }

    @Test func titleTemplatesFillFieldNames() {
        let fields: [String: FieldValue] = ["Rechnungsdatum": .date(date(2026, 2, 22)), "Betrag": .number(4.5), "N": .number(3)]
        #expect(TitleTemplate.fill("Tesla {Rechnungsdatum}", fields: fields)?.hasPrefix("Tesla 2026-02-2") == true)
        #expect(TitleTemplate.fill("{N} x {Betrag}", fields: fields) == "3 x 4.5")
    }

    @Test func aTemplateWithAMissingFieldOrNoPlaceholderGivesNil() {
        #expect(TitleTemplate.fill("Tesla {Fehlt}", fields: [:]) == nil)
        #expect(TitleTemplate.fill("Tesla", fields: ["A": .number(1)]) == nil)
    }
}
