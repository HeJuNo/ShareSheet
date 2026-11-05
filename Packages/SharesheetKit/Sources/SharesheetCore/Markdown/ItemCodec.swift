import Foundation

public enum CodecError: Error, Equatable {
    case missingFrontmatter
    case missingKey(String)
    case invalidValue(String)
}

public enum ItemCodec {
    private static let knownKeys: Set<String> = [
        "type", "url", "file", "title", "description", "tags", "favorite", "created", "created_manual", "title_manual", "field",
        "image", "screenshot", "screenshot_dark", "archive", "capture",
    ]
    private static let highlightsHeading = "## Highlights"
    private static let noteHeading = "## Note"

    // MARK: Encode

    public static func encode(_ item: Item) -> String {
        var lines = ["---"]
        lines.append("type: \(item.type.rawValue)")
        if let url = item.url { lines.append("url: \(quote(url.absoluteString))") }
        if let file = item.file { lines.append("file: \(quote(file))") }
        lines.append("title: \(quote(item.title))")
        if let description = item.description { lines.append("description: \(quote(description))") }
        lines.append("tags: [\(item.tags.map(quote).joined(separator: ", "))]")
        lines.append("favorite: \(item.favorite)")
        lines.append("created: \(isoFormatter().string(from: item.created))")
        if item.createdManual { lines.append("created_manual: true") }
        if item.titleManual { lines.append("title_manual: true") }
        for name in item.fields.keys.sorted() { lines.append("field: \(encodeField(name, item.fields[name]!))") }
        if let image = item.image { lines.append("image: \(quote(image))") }
        if let screenshot = item.screenshot { lines.append("screenshot: \(quote(screenshot))") }
        if let dark = item.screenshotDark { lines.append("screenshot_dark: \(quote(dark))") }
        if let archive = item.archive { lines.append("archive: \(quote(archive))") }
        if let capture = item.capture { lines.append("capture: \(capture.rawValue)") }
        lines.append(contentsOf: item.extraFrontmatter)
        lines.append("---")

        var parts: [String] = []
        if let content = item.content, !content.isEmpty {
            parts.append(content)
            if !item.note.isEmpty { parts.append("\(noteHeading)\n\n\(item.note)") }
        } else if !item.note.isEmpty {
            parts.append(item.type == .text ? "\(noteHeading)\n\n\(item.note)" : item.note)
        }
        if !item.highlights.isEmpty {
            let quotes = item.highlights.map { highlight in
                highlight.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { $0.isEmpty ? ">" : "> \($0)" }
                    .joined(separator: "\n")
            }
            parts.append(([highlightsHeading] + quotes).joined(separator: "\n\n"))
        }
        var body = parts.joined(separator: "\n\n")
        if !item.extraBody.isEmpty {
            body += (body.isEmpty ? "" : "\n\n") + item.extraBody
        }
        if !body.isEmpty && !body.hasSuffix("\n") { body += "\n" }

        let head = lines.joined(separator: "\n") + "\n"
        return body.isEmpty ? head : head + "\n" + body
    }

    // MARK: Decode

    public static func decode(_ text: String, id: ItemID) throws -> Item {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard all.first.map({ stripCR($0) }) == "---",
              let end = all.indices.dropFirst().first(where: { stripCR(all[$0]) == "---" })
        else { throw CodecError.missingFrontmatter }

        var values: [String: String] = [:]
        var extra: [String] = []
        var blockTags: [String]?
        var fieldLines: [String] = []
        var index = 1
        while index < end {
            let line = stripCR(all[index])
            index += 1
            if let colon = line.firstIndex(of: ":"),
               let first = line.first, !first.isWhitespace, first != "#", first != "-",
               knownKeys.contains(String(line[..<colon])) {
                let key = String(line[..<colon])
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if key == "tags", value.isEmpty {
                    var items: [String] = []
                    while index < end {
                        let next = stripCR(all[index]).trimmingCharacters(in: .whitespaces)
                        guard next == "-" || next.hasPrefix("- ") else { break }
                        items.append(try scalar(String(next.dropFirst()), key: "tags"))
                        index += 1
                    }
                    if !items.isEmpty { blockTags = items }
                }
                if key == "field" { fieldLines.append(value) } else { values[key] = value }
            } else {
                extra.append(line)
            }
        }

        func required(_ key: String) throws -> String {
            guard let raw = values[key] else { throw CodecError.missingKey(key) }
            return try scalar(raw, key: key)
        }
        func optional(_ key: String) throws -> String? {
            try values[key].map { try scalar($0, key: key) }
        }

        guard let type = ItemType(rawValue: try required("type")) else {
            throw CodecError.invalidValue("type")
        }
        let url: URL? = try optional("url").map {
            guard let url = URL(string: $0) else { throw CodecError.invalidValue("url") }
            return url
        }
        guard let created = isoFormatter().date(from: try required("created")) else {
            throw CodecError.invalidValue("created")
        }
        let capture: CaptureState? = try optional("capture").map {
            guard let state = CaptureState(rawValue: $0) else { throw CodecError.invalidValue("capture") }
            return state
        }
        let favorite: Bool
        switch values["favorite"] {
        case nil, "false": favorite = false
        case "true": favorite = true
        default: throw CodecError.invalidValue("favorite")
        }

        let createdManual: Bool
        switch values["created_manual"] {
        case nil, "false": createdManual = false
        case "true": createdManual = true
        default: throw CodecError.invalidValue("created_manual")
        }

        let titleManual: Bool
        switch values["title_manual"] {
        case nil, "false": titleManual = false
        case "true": titleManual = true
        default: throw CodecError.invalidValue("title_manual")
        }
        var fields: [String: FieldValue] = [:]
        for line in fieldLines {
            let (name, value) = try decodeField(line)
            fields[name] = value
        }

        var item = Item(
            id: id, type: type, url: url, file: try optional("file"), title: try required("title"),
            description: try optional("description"), tags: try blockTags ?? tags(values["tags"]),
            favorite: favorite, created: created, createdManual: createdManual, fields: fields, titleManual: titleManual, image: try optional("image"),
            screenshot: try optional("screenshot"), screenshotDark: try optional("screenshot_dark"),
            archive: try optional("archive"),
            capture: capture, extraFrontmatter: extra)

        // Body: drop the single blank separator line after the closing fence.
        var body = Array(all[(end + 1)...])
        if body.first == "" { body.removeFirst() }

        var pre = body
        if let h = body.lastIndex(of: highlightsHeading),
           let firstNonBlank = body[(h + 1)...].first(where: { !$0.isEmpty }),
           firstNonBlank.hasPrefix(">") {
            pre = Array(body[..<h])
            var i = h + 1
            var highlights: [String] = []
            while i < body.count {
                if body[i].isEmpty { i += 1; continue }
                guard body[i].hasPrefix(">") else { break }
                var block: [String] = []
                while i < body.count, body[i].hasPrefix(">") {
                    var line = body[i].dropFirst()
                    if line.first == " " { line = line.dropFirst() }
                    block.append(String(line))
                    i += 1
                }
                highlights.append(block.joined(separator: "\n"))
            }
            item.highlights = highlights
            item.extraBody = body[i...].joined(separator: "\n")
        }

        let main = trimNewlines(pre.joined(separator: "\n"))
        if type == .text {
            if main == noteHeading || main.hasPrefix("\(noteHeading)\n\n") {
                item.note = trimNewlines(String(main.dropFirst(noteHeading.count)))
            } else if let r = main.range(of: "\n\n\(noteHeading)\n\n", options: .backwards) {
                item.content = String(main[..<r.lowerBound])
                item.note = trimNewlines(String(main[r.upperBound...]))
            } else if main.hasSuffix("\n\n\(noteHeading)") {
                item.content = String(main.dropLast(noteHeading.count + 2))
            } else {
                item.content = main.isEmpty ? nil : main
            }
        } else {
            item.note = main
        }
        return item
    }

    // MARK: Helpers

    /// `["name", "type", "value"]` as a JSON array of strings; numbers use the shortest exact decimal form.
    private static func encodeField(_ name: String, _ value: FieldValue) -> String {
        let parts: [String]
        switch value {
        case .number(let number): parts = [name, "number", "\(number)"]
        case .date(let date): parts = [name, "date", isoFormatter().string(from: date)]
        case .text(let text): parts = [name, "text", text]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(parts)) ?? Data("[]".utf8), as: UTF8.self)
    }

    private static func decodeField(_ raw: String) throws -> (String, FieldValue) {
        guard let parts = try? JSONDecoder().decode([String].self, from: Data(raw.utf8)), parts.count == 3 else {
            throw CodecError.invalidValue("field")
        }
        switch parts[1] {
        case "number":
            guard let number = Double(parts[2]) else { throw CodecError.invalidValue("field") }
            return (parts[0], .number(number))
        case "date":
            guard let date = isoFormatter().date(from: parts[2]) else { throw CodecError.invalidValue("field") }
            return (parts[0], .date(date))
        case "text": return (parts[0], .text(parts[2]))
        default: throw CodecError.invalidValue("field")
        }
    }

    private static func isoFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    private static func stripCR(_ s: String) -> String {
        s.hasSuffix("\r") ? String(s.dropLast()) : s
    }

    private static func trimNewlines(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
    }

    private static func quote(_ s: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(s) else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Parses a quoted (JSON-escaped) or bare scalar.
    private static func scalar(_ raw: String, key: String) throws -> String {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("\"") {
            guard let value = try? JSONDecoder().decode(String.self, from: Data(s.utf8)) else {
                throw CodecError.invalidValue(key)
            }
            return value
        }
        if s.count >= 2, s.hasPrefix("'"), s.hasSuffix("'") {
            return String(s.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return s
    }

    private static func tags(_ raw: String?) throws -> [String] {
        guard let raw else { return [] }
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let data = s.data(using: .utf8), let list = try? JSONDecoder().decode([String].self, from: data) {
            return list
        }
        guard s.hasPrefix("["), s.hasSuffix("]") else {
            return s.isEmpty ? [] : [try scalar(s, key: "tags")]
        }
        let inner = s.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        if inner.isEmpty { return [] }
        return try inner.split(separator: ",").map { try scalar(String($0), key: "tags") }
    }
}
