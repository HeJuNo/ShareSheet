import Foundation
import Testing
import SharesheetCore
@testable import Sharesheet

@MainActor
struct RulesStatusTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "RulesStatus-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aBrokenFileGivesNoRulesAndAProblemUntilItIsFixed() async throws {
        let folder = try root()
        let status = RulesStatus()
        #expect(await RulesLoading.load(root: folder, status: status) == .empty)
        #expect(status.problem == nil)

        try Data("{ nope".utf8).write(to: folder.appending(path: RuleFile.name))
        #expect(await RulesLoading.load(root: folder, status: status) == .empty)
        #expect(status.problem?.isEmpty == false)

        let good = RuleSet(rules: [Rule(id: "r", name: "r", enabled: true, conditions: [RuleCondition(field: .url, op: .contains, value: "a")], actions: [.addTag("x")])])
        try good.encoded().write(to: folder.appending(path: RuleFile.name))
        #expect(await RulesLoading.load(root: folder, status: status) == good)
        #expect(status.problem == nil)
    }

    @Test func noLibraryMeansNoRulesAndNoProblem() async {
        let status = RulesStatus()
        #expect(await RulesLoading.load(root: nil, status: status) == .empty)
        #expect(status.problem == nil)
    }
}
