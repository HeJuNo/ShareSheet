import Foundation
import Testing
@testable import Sharesheet
import SharesheetCore

/// The identifiers follow the team the app is built for; the code must read the ones the build wrote.
struct IdentifierTests {
    private let bundleID = Bundle.main.bundleIdentifier ?? ""

    @Test func appGroupAndICloudContainerFollowTheBundleIdentifier() {
        #expect(AppGroup.identifier == "group.\(bundleID)")
        #expect(ICloudLocator.containerIdentifier == "iCloud.\(bundleID)")
    }

    @Test func backgroundTaskIsPermittedByInfoPlist() {
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
        #expect(permitted == [BackgroundCapture.identifier])
    }

    @Test func iCloudContainerIsDeclaredForTheFilesApp() {
        let containers = Bundle.main.object(forInfoDictionaryKey: "NSUbiquitousContainers") as? [String: Any]
        #expect(containers?.keys.sorted() == [ICloudLocator.containerIdentifier])
    }
}
