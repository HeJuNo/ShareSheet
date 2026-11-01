import Foundation
import Testing
@testable import Sharesheet
import SharesheetCore

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

struct ICloudLibraryTests {
    @Test func concurrentResolvesShareOneStore() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ICloudLibraryTests-\(UUID().uuidString)")
        let calls = Calls()
        let library = ICloudLibrary {
            calls.increment()
            try? await Task.sleep(for: .milliseconds(100))
            return root
        }

        let stores = await withTaskGroup(of: (any ItemStore)?.self) { group in
            for _ in 0..<8 { group.addTask { await library.resolve() } }
            return await group.reduce(into: [(any ItemStore)?]()) { $0.append($1) }
        }

        #expect(calls.count == 1)
        let first = try #require(stores.first ?? nil) as AnyObject
        #expect(stores.allSatisfy { ($0 as AnyObject?) === first })
    }

    @Test func anUnavailableLibraryIsAskedAgain() async throws {
        let calls = Calls()
        let library = ICloudLibrary {
            calls.increment()
            return nil
        }

        #expect(await library.resolve() == nil)
        #expect(await library.resolve() == nil)
        #expect(calls.count == 2)
    }
}
