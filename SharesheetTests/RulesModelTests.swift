import Foundation
import Testing
import SharesheetCore
@testable import Sharesheet

@MainActor
struct RulesModelTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "RulesModel-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func model(_ root: URL?) -> RulesModel {
        RulesModel(root: { root }, applier: nil, itemIDs: { [] })
    }
    private let anyRule = Rule(
        id: "r", name: "Tech", enabled: true, match: .any,
        conditions: [RuleCondition(field: .url, op: .contains, value: "apple.com"), RuleCondition(field: .url, op: .contains, value: "microsoft.com")],
        actions: [.addTag("tech")])

    @Test func noFileIsReadyAndEmptyAndSavingWritesMatchAny() async throws {
        let root = try folder()
        let model = model(root)
        await model.reload()
        #expect(model.state == .ready && model.rules.isEmpty)
        try await model.save([anyRule])
        let text = try String(contentsOf: root.appending(path: RuleFile.name), encoding: .utf8)
        #expect(text.contains("\"match\" : \"any\""))
        let again = self.model(root)
        await again.reload()
        #expect(again.rules == [anyRule])
    }

    @Test func aBrokenFileBlocksSavingUntilANewFileIsStartedOnPurpose() async throws {
        let root = try folder()
        let file = root.appending(path: RuleFile.name)
        try Data("{ my hand written rules".utf8).write(to: file)
        let model = model(root)
        await model.reload()
        guard case .blocked(let message) = model.state else { Issue.record("expected blocked"); return }
        #expect(!message.isEmpty)

        await #expect(throws: (any Error).self) { try await model.save([anyRule]) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "{ my hand written rules")

        try await model.startNewFile()
        #expect(model.state == .ready && model.rules.isEmpty)
        #expect(try String(contentsOf: root.appending(path: "rules.json.broken"), encoding: .utf8) == "{ my hand written rules")
        try await model.save([anyRule])
        #expect(RuleFile.load(from: root) == .rules(RuleSet(rules: [anyRule])))
    }

    @Test func startingANewFileIsOnlyPossibleWhenBlocked() async throws {
        let root = try folder()
        let model = model(root)
        await model.reload()
        await #expect(throws: (any Error).self) { try await model.startNewFile() }
    }

    @Test func withoutALibraryNothingCanBeSaved() async throws {
        let model = model(nil)
        await model.reload()
        #expect(model.state == .unavailable)
        await #expect(throws: (any Error).self) { try await model.save([anyRule]) }
    }
}
