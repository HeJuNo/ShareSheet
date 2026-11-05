import Foundation
import Testing
@testable import SharesheetCore

@Suite struct DateExtractorTests {
    private let vienna = TimeZone(identifier: "Europe/Vienna")!
    private let pattern = "Ihr Einkauf am {Datum} um {Uhrzeit} Uhr"

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, _ s: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = vienna
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!
    }

    private func extract(_ text: String, _ pattern: String? = nil) -> Date? {
        DateExtractor.date(in: text, pattern: pattern ?? self.pattern, timeZone: vienna)
    }

    @Test func theExampleFromTheReceiptGivesDateAndTime() {
        #expect(extract("Rechnung\nIhr Einkauf am 02.11.2026 um 15:08 Uhr\nDanke") == date(2026, 11, 2, 15, 8))
    }

    @Test func lineBreaksCaseAndSpacingInTheTextDoNotMatter() {
        #expect(extract("ihr einkauf\nAM 02.11.2026   um\n15:08 uhr") == date(2026, 11, 2, 15, 8))
    }

    @Test func shortYearDotTimeSecondsAndMissingTime() {
        #expect(extract("Einkauf am 2.11.26", "Einkauf am {Datum}") == date(2026, 11, 2))
        #expect(extract("am 02.11.2026 um 15.08 Uhr", "am {Datum} um {Uhrzeit} Uhr") == date(2026, 11, 2, 15, 8))
        #expect(extract("am 02.11.2026 um 15:08:09 Uhr", "am {Datum} um {Uhrzeit} Uhr") == date(2026, 11, 2, 15, 8, 9))
    }

    @Test func theTimeMayComeBeforeTheDate() {
        #expect(extract("Um 15:08 Uhr am 02.11.2026", "Um {Uhrzeit} Uhr am {Datum}") == date(2026, 11, 2, 15, 8))
    }

    @Test func invalidValuesGiveNothing() {
        #expect(extract("Einkauf am 31.02.2026", "Einkauf am {Datum}") == nil)
        #expect(extract("Einkauf am 02.13.2026", "Einkauf am {Datum}") == nil)
        #expect(extract("am 02.11.2026 um 25:61 Uhr", "am {Datum} um {Uhrzeit} Uhr") == nil)
        #expect(extract("Einkauf am 02.11.20267", "Einkauf am {Datum}") == nil)
    }

    @Test func noMatchGivesNothingAndLiteralTextIsNotARegex() {
        #expect(extract("Kein Datum hier") == nil)
        #expect(extract("Betrag (EUR) vom 02.11.2026", "Betrag (EUR) vom {Datum}") == date(2026, 11, 2))
        #expect(extract("Betrag EUR vom 02.11.2026", "Betrag (EUR) vom {Datum}") == nil)
        #expect(extract("1+1 am 02.11.2026", "1+1 am {Datum}") == date(2026, 11, 2))
    }

    @Test func theFirstMatchDecides() {
        let text = "Einkauf am 02.11.2026 und Einkauf am 05.12.2026"
        #expect(extract(text, "Einkauf am {Datum}") == date(2026, 11, 2))
    }

    @Test func aPatternNeedsExactlyOneDateAndAtMostOneTime() {
        #expect(DateExtractor.isValid(pattern: "{Datum}"))
        #expect(DateExtractor.isValid(pattern: "Einkauf am {Datum} um {Uhrzeit} Uhr"))
        #expect(!DateExtractor.isValid(pattern: ""))
        #expect(!DateExtractor.isValid(pattern: "Einkauf"))
        #expect(!DateExtractor.isValid(pattern: "{Uhrzeit}"))
        #expect(!DateExtractor.isValid(pattern: "{Datum} und {Datum}"))
        #expect(!DateExtractor.isValid(pattern: "{Datum} {Uhrzeit} {Uhrzeit}"))
        #expect(DateExtractor.date(in: "02.11.2026", pattern: "{Datum} {Datum}", timeZone: vienna) == nil)
    }
}

@Suite struct DateExtractorSlashAndIsoTests {
    @Test func yearFirstFormatsAreRead() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Vienna")!
        let expected = calendar.date(from: DateComponents(year: 2026, month: 2, day: 22))!
        for text in ["Rechnungsdatum 2026/02/22", "Rechnungsdatum 2026-02-22"] {
            #expect(DateExtractor.date(in: text, pattern: "Rechnungsdatum {Datum}", timeZone: calendar.timeZone) == expected)
        }
        #expect(DateExtractor.date(in: "Rechnungsdatum 2026/13/22", pattern: "Rechnungsdatum {Datum}") == nil)
    }
}
