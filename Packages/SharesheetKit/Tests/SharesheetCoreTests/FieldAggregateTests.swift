import Foundation
import Testing
@testable import SharesheetCore

@Suite struct FieldAggregateTests {
    private let values = [2.0, 4, 4, 4, 5, 5, 7, 9]

    @Test func basicAggregates() {
        #expect(FieldAggregate.sum.value(of: values) == 40)
        #expect(FieldAggregate.average.value(of: values) == 5)
        #expect(FieldAggregate.min.value(of: values) == 2)
        #expect(FieldAggregate.max.value(of: values) == 9)
        #expect(FieldAggregate.count.value(of: values) == 8)
    }

    @Test func medianOfEvenAndOddCounts() {
        #expect(FieldAggregate.median.value(of: values) == 4.5)
        #expect(FieldAggregate.median.value(of: [3, 1, 2]) == 2)
    }

    @Test func standardDeviationIsTheSampleDeviation() throws {
        let sd = try #require(FieldAggregate.stdDev.value(of: values))
        #expect(abs(sd - 2.13809) < 0.0001)
    }

    @Test func tooFewValuesGiveNoResultInsteadOfCrashing() {
        #expect(FieldAggregate.stdDev.value(of: [5]) == nil)
        #expect(FieldAggregate.stdDev.value(of: []) == nil)
        for aggregate in FieldAggregate.allCases where aggregate != .count { #expect(aggregate.value(of: []) == nil) }
        #expect(FieldAggregate.sum.value(of: [5]) == 5)
    }
}
