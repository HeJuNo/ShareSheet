import Testing
import SharesheetCore
@testable import Sharesheet

struct TagFilterTests {
    @Test func aTagIsEitherWithOrWithoutAndTogglesOff() {
        var filter = TagFilter()
        filter.toggleIncluded("Rechnung")
        filter.toggleExcluded("rechnung")
        #expect(filter.included.isEmpty && filter.excluded == ["rechnung"])
        filter.toggleExcluded("Rechnung")
        #expect(filter.isEmpty)
    }

    @Test func appliesBothListsToTheQuery() {
        var filter = TagFilter()
        filter.toggleIncluded("Strom")
        filter.toggleExcluded("Gas")
        var query = LibraryQuery(scope: .all)
        filter.apply(to: &query)
        #expect(query.tags == ["Strom"] && query.excludedTags == ["Gas"])
    }
}
