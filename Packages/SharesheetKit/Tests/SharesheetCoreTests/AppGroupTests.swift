import Testing
@testable import SharesheetCore

@Test func appGroupIdentifierMatchesEntitlements() {
    #expect(AppGroup.identifier.hasPrefix("group."))
}
