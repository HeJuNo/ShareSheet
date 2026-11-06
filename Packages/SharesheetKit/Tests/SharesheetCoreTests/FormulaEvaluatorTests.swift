import Foundation
import Testing
@testable import SharesheetCore

@Suite struct FormulaEvaluatorTests {
    private func eval(_ f: String, _ fields: [String: Double] = [:]) -> Double? { FormulaEvaluator.evaluate(f, fields: fields) }

    @Test func multiplicationBindsStrongerThanAddition() {
        #expect(eval("2 + 3 * 4") == 14)
        #expect(eval("(2 + 3) * 4") == 20)
        #expect(eval("10 - 4 - 3") == 3)
        #expect(eval("100 / 5 / 2") == 10)
    }

    @Test func unaryMinusAndDecimals() {
        #expect(eval("-3 + 5") == 2)
        #expect(eval("2 * -1.5") == -3)
        #expect(eval("-(1 + 2)") == -3)
    }

    @Test func fieldReferencesMayContainSpaces() {
        #expect(eval("{Netto} + {Mehrwert Steuer}", ["Netto": 10, "Mehrwert Steuer": 1.9]) == 11.9)
    }

    @Test func invalidInputGivesNil() {
        #expect(eval("1 +") == nil)
        #expect(eval("(1 + 2") == nil)
        #expect(eval("1 / 0") == nil)
        #expect(eval("{Fehlt} + 1") == nil)
        #expect(eval("abc") == nil)
        #expect(eval("") == nil)
        #expect(eval("1 2") == nil)
    }

    @Test func referencesAreListedInOrderWithoutRepeats() {
        #expect(FormulaEvaluator.references(in: "{A} + {B} * {A}") == ["A", "B"])
        #expect(FormulaEvaluator.references(in: "1 + 2") == [])
        #expect(FormulaEvaluator.references(in: "{A} +") == nil)
    }
}
