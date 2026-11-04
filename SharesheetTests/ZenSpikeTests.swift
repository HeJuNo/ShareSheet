import Foundation
import Testing
import ZenUniffi

/// Pins down how ZEN behaves for the rules feature (found by trying it on the simulator):
/// - values from rules are passed in the context (`rv`), never written into expressions
/// - cells of an expression input column are unary expressions on `$`: `contains($, "svs")`
/// - several input columns on the same field are all ANDed within a row
/// - hit policy `collect` returns the matching rows' outputs (see `expectedShape` below)
struct ZenSpikeTests {
    private func decision(cells: [[String]], outputs: [String]) throws -> Data {
        // inputs: one column per cell position, all on field "text".
        let inputIds = (0..<cells[0].count).map { "in\($0)" }
        let outputIds = (0..<outputs.count).map { "out\($0)" }
        let inputs = inputIds.map { ["id": $0, "name": $0, "field": "text", "type": "expression"] }
        let outputCols = zip(outputIds, ["moveTo", "addTags"]).map { ["id": $0, "name": $1, "field": $1, "type": "expression"] }
        let rules: [[String: String]] = cells.enumerated().map { row, cells in
            var rule = ["_id": "r\(row)"]
            for (i, cell) in cells.enumerated() { rule[inputIds[i]] = cell }
            for (i, out) in outputs.enumerated() { rule[outputIds[i]] = out }
            return rule
        }
        let graph: [String: Any] = [
            "nodes": [
                ["id": "i", "type": "inputNode", "name": "Request", "position": ["x": 0, "y": 0]],
                ["id": "t", "type": "decisionTableNode", "name": "Rules", "position": ["x": 100, "y": 0],
                 "content": ["hitPolicy": "collect", "inputs": inputs, "outputs": Array(outputCols.prefix(outputs.count)), "rules": rules]],
                ["id": "o", "type": "outputNode", "name": "Response", "position": ["x": 200, "y": 0]],
            ],
            "edges": [
                ["id": "e1", "sourceId": "i", "type": "edge", "targetId": "t"],
                ["id": "e2", "sourceId": "t", "type": "edge", "targetId": "o"],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: graph)
    }

    private func result(of graph: Data, text: String, values: [String] = []) async throws -> String {
        let engine = try ZenEngine(loader: nil, customNode: nil)
        let decision = try engine.createDecision(content: graph)
        let context = try JSONSerialization.data(withJSONObject: ["text": text, "rv": values])
        let response = try await decision.evaluate(context: context, options: nil)
        return String(data: response.result, encoding: .utf8) ?? ""
    }

    // Result shape (collect): a JSON array with one object per matching row, e.g. [{"moveTo":"X"},{"addTags":["a"]}];
    // no matching row gives []. A row whose condition cells are all empty matches every item.
    @Test func containsAndCollectWorkOnTheSimulator() async throws {
        let graph = try decision(
            cells: [[#"contains($, "svs")"#, #"contains($, "kontoauszug")"#]], outputs: [#""Sozialversicherung""#])
        #expect(try await result(of: graph, text: "svs kontoauszug") == #"[{"moveTo":"Sozialversicherung"}]"#)
        #expect(try await result(of: graph, text: "svs") == "[]")
        #expect(try await result(of: graph, text: "kontoauszug") == "[]")
    }

    @Test func aRowWithOnlyEmptyCellsMatchesEverything() async throws {
        let graph = try decision(cells: [[""]], outputs: [#""X""#])
        #expect(try await result(of: graph, text: "anything") == #"[{"moveTo":"X"}]"#)
    }

    @Test func listOutputsComeBackAsArrays() async throws {
        let graph = try decision(cells: [[#"contains($, "apple")"#]], outputs: [#""M""#, #"["apple", "tech"]"#])
        let actual = try await result(of: graph, text: "apple.com")
        let rows = try #require(JSONSerialization.jsonObject(with: Data(actual.utf8)) as? [[String: Any]])
        #expect(rows.count == 1 && rows[0]["moveTo"] as? String == "M" && rows[0]["addTags"] as? [String] == ["apple", "tech"])
    }

    // User values never go into an expression: they travel in the context list `rv` and cells only index it.
    @Test func valuesFromTheContextAreMatchedLiterally() async throws {
        let value = "it's \"q\" \\ $x\nline"
        let graph = try decision(cells: [["contains($, rv[0])"]], outputs: [#""hit""#])
        #expect(try await result(of: graph, text: "before \(value) after", values: [value]) == #"[{"moveTo":"hit"}]"#)
        #expect(try await result(of: graph, text: "nothing", values: [value]) == "[]")
    }
}
