import Foundation
import GRDB

public enum LibraryScope: Hashable, Sendable {
    case all, unsorted, favorites, highlights
    case type(ItemType)
    /// Includes nested collections.
    case collection(CollectionPath)
}

public struct LibraryQuery: Sendable {
    public var text: String?
    public var scope: LibraryScope
    public var tag: String?

    public init(text: String? = nil, scope: LibraryScope, tag: String? = nil) {
        self.text = text
        self.scope = scope
        self.tag = tag
    }
}

public struct IndexedItem: Identifiable, Equatable, Sendable {
    public var id: ItemID
    public var type: ItemType
    public var title: String
    public var url: URL?
    public var domain: String?
    public var file: String?
    public var tags: [String]
    public var created: Date
    public var capture: CaptureState?
    public var favorite: Bool
    public var hasHighlights: Bool

    public init(
        id: ItemID, type: ItemType, title: String, url: URL? = nil, domain: String? = nil,
        file: String? = nil, tags: [String] = [], created: Date, capture: CaptureState? = nil,
        favorite: Bool = false, hasHighlights: Bool = false
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.url = url
        self.domain = domain
        self.file = file
        self.tags = tags
        self.created = created
        self.capture = capture
        self.favorite = favorite
        self.hasHighlights = hasHighlights
    }
}

public struct LibraryCounts: Equatable, Sendable {
    public var all = 0, unsorted = 0, favorites = 0, highlights = 0
    public var byType: [ItemType: Int] = [:]
    /// Nested counts roll up into every ancestor.
    public var byCollection: [CollectionPath: Int] = [:]

    public init() {}
}

public struct Keyword: Equatable, Hashable, Sendable, Codable {
    public var term: String
    public var score: Double

    public init(term: String, score: Double) {
        self.term = term
        self.score = score
    }
}

/// An item with a file or archive that has not been analysed yet. `source` is the file path, else the archive path.
public struct AnalysisCandidate: Equatable, Sendable {
    public var id: ItemID
    public var source: String
    public var isFile: Bool
}

public struct ItemAnalysis: Equatable, Sendable {
    public var keywords: [Keyword]
    public var suggestedTag: String?
}

/// Rebuildable SQLite index of the Markdown library. Written by the app, opened read-only by the share extension.
public final class LibraryIndex: Sendable {
    private let pool: DatabasePool

    /// `observesSuspension`: the database lives in the shared App Group container, so a process holding it open
    /// while suspended is killed by the system (0xdead10cc). Such an index follows `suspend()` / `resume()`.
    public init(path: URL, readOnly: Bool = false, observesSuspension: Bool = false) throws {
        var config = Configuration()
        config.readonly = readOnly
        config.observesSuspensionNotifications = observesSuspension
        pool = try DatabasePool(path: path.path, configuration: config)
        if !readOnly { try Self.migrator.migrate(pool) }
    }

    /// Makes every observing index give up its locks and refuse access until `resume()`; call it before the
    /// process is suspended (going to the background, the end of a background task).
    public static func suspend() {
        NotificationCenter.default.post(name: Database.suspendNotification, object: nil)
    }

    public static func resume() {
        NotificationCenter.default.post(name: Database.resumeNotification, object: nil)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "items") { t in
                t.autoIncrementedPrimaryKey("key")
                t.column("id", .text).notNull().unique()
                t.column("type", .text).notNull()
                t.column("title", .text).notNull()
                t.column("url", .text)
                t.column("domain", .text)
                t.column("file", .text)
                t.column("created", .double).notNull()
                t.column("capture", .text)
                t.column("favorite", .boolean).notNull()
                t.column("has_highlights", .boolean).notNull()
                t.column("collection", .text).notNull()
                t.column("note", .text).notNull()
                t.column("description", .text)
                t.column("highlights", .text).notNull()
                t.column("archive", .text)
            }
            try db.create(index: "items_created", on: "items", columns: ["created"])
            try db.create(index: "items_collection", on: "items", columns: ["collection"])
            try db.create(table: "item_tags") { t in
                t.column("item_id", .text).notNull().references("items", column: "id", onDelete: .cascade)
                t.column("tag", .text).notNull()
                t.column("position", .integer).notNull()
            }
            try db.create(index: "item_tags_item", on: "item_tags", columns: ["item_id"])
            try db.create(index: "item_tags_tag", on: "item_tags", columns: ["tag"])
            try db.create(table: "archive_text") { t in
                t.primaryKey("archive", .text)
                t.column("text", .text).notNull()
            }
            try db.create(table: "favicons") { t in
                t.primaryKey("host", .text)
                t.column("data", .blob).notNull()
            }
            try db.create(virtualTable: "items_fts", using: FTS5()) { t in
                t.tokenizer = .unicode61(diacritics: .remove)
                t.column("title")
                t.column("note")
                t.column("description")
                t.column("url")
                t.column("highlights")
                t.column("archive_text")
            }
        }
        // Analysis rows are keyed by source path and deliberately not tied to `items`: re-indexing deletes and
        // re-inserts item rows, and the analysis has to survive that.
        migrator.registerMigration("v2") { db in
            try db.create(table: "analysis") { t in
                t.primaryKey("source", .text)
                t.column("doc_text", .text).notNull().defaults(to: "")
                t.column("keywords_json", .text).notNull().defaults(to: "[]")
                t.column("suggested_tag", .text)
            }
            try db.drop(table: "items_fts")
            try db.create(virtualTable: "items_fts", using: FTS5()) { t in
                t.tokenizer = .unicode61(diacritics: .remove)
                t.column("title")
                t.column("note")
                t.column("description")
                t.column("url")
                t.column("highlights")
                t.column("archive_text")
                t.column("doc_text")
                t.column("keywords")
            }
            for key in try Int64.fetchAll(db, sql: "SELECT key FROM items") { try refreshFTS(key: key, db) }
        }
        return migrator
    }

    // MARK: Writing

    public func replaceAll(with items: [Item]) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM items_fts")
            try db.execute(sql: "DELETE FROM item_tags")
            try db.execute(sql: "DELETE FROM items")
            for item in items { try Self.insert(item, db) }
        }
    }

    public func upsert(_ item: Item) throws {
        try pool.write { db in
            try Self.delete(item.id, db)
            try Self.insert(item, db)
        }
    }

    public func remove(_ id: ItemID) throws {
        try pool.write { db in try Self.delete(id, db) }
    }

    public func setArchiveText(_ text: String, forArchive path: String) throws {
        try pool.write { db in
            try db.execute(
                sql: "INSERT INTO archive_text(archive, text) VALUES (?, ?) ON CONFLICT(archive) DO UPDATE SET text = excluded.text",
                arguments: [path, text])
            let keys = try Int64.fetchAll(db, sql: "SELECT key FROM items WHERE archive = ?", arguments: [path])
            for key in keys { try Self.refreshFTS(key: key, db) }
        }
    }

    /// `text` is the extracted document text of a file, nil for an archive (its text lives in `archive_text`).
    public func setAnalysis(source: String, text: String?, keywords: [Keyword], suggestedTag: String?) throws {
        let json = String(decoding: try JSONEncoder().encode(keywords), as: UTF8.self)
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO analysis(source, doc_text, keywords_json, suggested_tag) VALUES (?, ?, ?, ?)
                ON CONFLICT(source) DO UPDATE SET doc_text = excluded.doc_text,
                    keywords_json = excluded.keywords_json, suggested_tag = excluded.suggested_tag
                """, arguments: [source, text ?? "", json, suggestedTag])
            try Self.refreshFTS(source: source, db)
        }
    }

    public func setSuggestedTag(_ tag: String?, forSource source: String) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE analysis SET suggested_tag = ? WHERE source = ?", arguments: [tag, source])
        }
    }

    /// Same as `setSuggestedTag(_:forSource:)`, for the source (file, else archive) of the item with this id.
    public func setSuggestedTag(_ tag: String?, forItem id: ItemID) throws {
        try pool.write { db in
            try db.execute(sql: """
                UPDATE analysis SET suggested_tag = ?
                WHERE source = (SELECT COALESCE(file, archive) FROM items WHERE id = ?)
                """, arguments: [tag, id.relativePath])
        }
    }

    public func clearAnalysis() throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM analysis")
            for key in try Int64.fetchAll(db, sql: "SELECT key FROM items") { try Self.refreshFTS(key: key, db) }
        }
    }

    public func setFavicon(_ data: Data, host: String) throws {
        try pool.write { db in
            try db.execute(
                sql: "INSERT INTO favicons(host, data) VALUES (?, ?) ON CONFLICT(host) DO UPDATE SET data = excluded.data",
                arguments: [host, data])
        }
    }

    // MARK: Reading

    public func favicon(host: String) throws -> Data? {
        try pool.read { db in
            try Data.fetchOne(db, sql: "SELECT data FROM favicons WHERE host = ?", arguments: [host])
        }
    }

    public func analysisCandidates() throws -> [AnalysisCandidate] {
        try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, file, archive FROM items
                WHERE COALESCE(file, archive) IS NOT NULL
                  AND NOT EXISTS (SELECT 1 FROM analysis WHERE source = COALESCE(items.file, items.archive))
                ORDER BY created DESC, id
                """).map { row in
                let file: String? = row["file"]
                let archive: String? = row["archive"]
                return AnalysisCandidate(
                    id: ItemID(relativePath: row["id"]), source: (file ?? archive)!, isFile: file != nil)
            }
        }
    }

    public func analysis(forItem id: ItemID) throws -> ItemAnalysis? {
        try pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT analysis.keywords_json, analysis.suggested_tag FROM items
                JOIN analysis ON analysis.source = COALESCE(items.file, items.archive)
                WHERE items.id = ?
                """, arguments: [id.relativePath]) else { return nil }
            let json: String = row["keywords_json"]
            let keywords = (try? JSONDecoder().decode([Keyword].self, from: Data(json.utf8))) ?? []
            return ItemAnalysis(
                keywords: keywords.sorted { $0.score > $1.score }, suggestedTag: row["suggested_tag"])
        }
    }

    /// The document text of a file item, or the archive text of a web item.
    public func analysisText(forItem id: ItemID) throws -> String? {
        try pool.read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT file, archive FROM items WHERE id = ?", arguments: [id.relativePath]) else { return nil }
            if let file: String = row["file"] {
                return try String.fetchOne(db, sql: "SELECT doc_text FROM analysis WHERE source = ?", arguments: [file])
            }
            if let archive: String = row["archive"] {
                return try String.fetchOne(db, sql: "SELECT text FROM archive_text WHERE archive = ?", arguments: [archive])
            }
            return nil
        }
    }

    /// `documents`: items that have an analysis row, archive text or document text; `frequencies[term]`: how many of
    /// them contain the term in their document text, archive text or title.
    public func documentFrequencies(of terms: [String]) throws -> (documents: Int, frequencies: [String: Int]) {
        try pool.read { db in
            let isDocument = """
                (EXISTS (SELECT 1 FROM analysis WHERE source = COALESCE(items.file, items.archive))
                 OR EXISTS (SELECT 1 FROM archive_text WHERE archive = items.archive))
                """
            let documents = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items WHERE \(isDocument)") ?? 0
            var frequencies: [String: Int] = [:]
            for term in terms {
                let cleaned = term.replacingOccurrences(of: "\"", with: "")
                guard !cleaned.isEmpty else { continue }
                frequencies[term] = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM items JOIN items_fts ON items_fts.rowid = items.key
                    WHERE items_fts MATCH ? AND \(isDocument)
                    """, arguments: ["{doc_text archive_text title} : \"\(cleaned)\""]) ?? 0
            }
            return (documents, frequencies)
        }
    }

    public func search(_ query: LibraryQuery) throws -> [IndexedItem] {
        try pool.read { db in
            var sql = "SELECT items.* FROM items"
            var conditions: [String] = []
            var args = StatementArguments()

            let match = Self.ftsExpression(query.text)
            let hasText = match != nil
            if let match {
                sql += " JOIN items_fts ON items_fts.rowid = items.key"
                conditions.append("items_fts MATCH ?")
                args += [match]
            }
            switch query.scope {
            case .all: break
            case .unsorted:
                conditions.append("items.collection = ?")
                args += [CollectionPath.unsorted.relativePath]
            case .favorites: conditions.append("items.favorite = 1")
            case .highlights: conditions.append("items.has_highlights = 1")
            case .type(let type):
                conditions.append("items.type = ?")
                args += [type.rawValue]
            case .collection(let path):
                if !path.components.isEmpty {
                    let name = path.relativePath
                    conditions.append("(items.collection = ? OR substr(items.collection, 1, ?) = ?)")
                    // SQLite substr counts code points, not grapheme clusters.
                    args += [name, name.unicodeScalars.count + 1, name + "/"]
                }
            }
            if let tag = query.tag {
                conditions.append("EXISTS (SELECT 1 FROM item_tags WHERE item_id = items.id AND tag = ? COLLATE NOCASE)")
                args += [tag]
            }
            if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
            // Columns: title, note, description, url, highlights, archive_text, doc_text, keywords.
            sql += hasText
                ? " ORDER BY bm25(items_fts, 8, 4, 3, 1, 3, 1, 1, 6), items.created DESC, items.id"
                : " ORDER BY items.created DESC, items.id"

            let rows = try Row.fetchAll(db, sql: sql, arguments: args)
            return try rows.map { row in
                let id: String = row["id"]
                let tags = try String.fetchAll(
                    db, sql: "SELECT tag FROM item_tags WHERE item_id = ? ORDER BY position", arguments: [id])
                return IndexedItem(
                    id: ItemID(relativePath: id),
                    type: ItemType(rawValue: row["type"]) ?? .link,
                    title: row["title"],
                    url: (row["url"] as String?).flatMap { URL(string: $0) },
                    domain: row["domain"],
                    file: row["file"],
                    tags: tags,
                    created: Date(timeIntervalSince1970: row["created"]),
                    capture: (row["capture"] as String?).flatMap { CaptureState(rawValue: $0) },
                    favorite: row["favorite"],
                    hasHighlights: row["has_highlights"])
            }
        }
    }

    public func counts() throws -> LibraryCounts {
        try pool.read { db in
            var counts = LibraryCounts()
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS n, COALESCE(SUM(collection = ?), 0) AS u,
                       COALESCE(SUM(favorite), 0) AS f, COALESCE(SUM(has_highlights), 0) AS h FROM items
                """, arguments: [CollectionPath.unsorted.relativePath])!
            counts.all = row["n"]; counts.unsorted = row["u"]
            counts.favorites = row["f"]; counts.highlights = row["h"]
            for r in try Row.fetchAll(db, sql: "SELECT type, COUNT(*) AS n FROM items GROUP BY type") {
                if let type = ItemType(rawValue: r["type"]) { counts.byType[type] = r["n"] }
            }
            for r in try Row.fetchAll(db, sql: "SELECT collection, COUNT(*) AS n FROM items GROUP BY collection") {
                let n: Int = r["n"]
                var path: CollectionPath? = CollectionPath(
                    components: (r["collection"] as String).split(separator: "/").map(String.init))
                while let p = path, !p.components.isEmpty {
                    counts.byCollection[p, default: 0] += n
                    path = p.parent
                }
            }
            return counts
        }
    }

    /// The item whose URL equals `url` once tracking parameters are stripped from both.
    public func itemID(forURL url: URL) throws -> ItemID? {
        let target = URLCleaner.clean(url)
        return try pool.read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT id, url FROM items WHERE domain IS ? AND url IS NOT NULL ORDER BY created",
                arguments: [Self.domain(of: target)])
            for row in rows {
                let candidate: String = row["url"]
                if let candidateURL = URL(string: candidate), URLCleaner.clean(candidateURL) == target {
                    return ItemID(relativePath: row["id"])
                }
            }
            return nil
        }
    }

    public func allTags() throws -> [String] {
        try pool.read { db in
            try String.fetchAll(db, sql: "SELECT tag FROM item_tags GROUP BY tag ORDER BY COUNT(*) DESC, tag")
        }
    }

    // MARK: Helpers

    /// `"tok"*` per whitespace-separated token, AND-ed; nil when there is nothing to match.
    private static func ftsExpression(_ text: String?) -> String? {
        let tokens = (text ?? "").split(whereSeparator: \.isWhitespace)
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
            .map { "\"\($0)\"*" }
        return tokens.isEmpty ? nil : tokens.joined(separator: " AND ")
    }

    private static func insert(_ item: Item, _ db: Database) throws {
        let id = item.id.relativePath
        try db.execute(sql: """
            INSERT INTO items(id, type, title, url, domain, file, created, capture, favorite, has_highlights,
                              collection, note, description, highlights, archive)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                id, item.type.rawValue, item.title, item.url?.absoluteString, domain(of: item.url), item.file,
                item.created.timeIntervalSince1970, item.capture?.rawValue, item.favorite, !item.highlights.isEmpty,
                item.id.collection.relativePath, item.note, item.description,
                item.highlights.joined(separator: "\n"), item.archive,
            ])
        let key = db.lastInsertedRowID
        for (position, tag) in item.tags.enumerated() {
            try db.execute(
                sql: "INSERT INTO item_tags(item_id, tag, position) VALUES (?, ?, ?)", arguments: [id, tag, position])
        }
        try refreshFTS(key: key, db)
    }

    private static func delete(_ id: ItemID, _ db: Database) throws {
        if let key = try Int64.fetchOne(db, sql: "SELECT key FROM items WHERE id = ?", arguments: [id.relativePath]) {
            try db.execute(sql: "DELETE FROM items_fts WHERE rowid = ?", arguments: [key])
        }
        try db.execute(sql: "DELETE FROM item_tags WHERE item_id = ?", arguments: [id.relativePath])
        try db.execute(sql: "DELETE FROM items WHERE id = ?", arguments: [id.relativePath])
    }

    private static func refreshFTS(key: Int64, _ db: Database) throws {
        try db.execute(sql: "DELETE FROM items_fts WHERE rowid = ?", arguments: [key])
        let analysis = try Row.fetchOne(db, sql: """
            SELECT analysis.doc_text, analysis.keywords_json FROM items
            JOIN analysis ON analysis.source = COALESCE(items.file, items.archive) WHERE items.key = ?
            """, arguments: [key])
        let docText: String = analysis?["doc_text"] ?? ""
        let json: String = analysis?["keywords_json"] ?? "[]"
        let keywords = ((try? JSONDecoder().decode([Keyword].self, from: Data(json.utf8))) ?? [])
            .map(\.term).joined(separator: " ")
        try db.execute(sql: """
            INSERT INTO items_fts(rowid, title, note, description, url, highlights, archive_text, doc_text, keywords)
            SELECT items.key, items.title, items.note, COALESCE(items.description, ''), COALESCE(items.url, ''),
                   items.highlights, COALESCE((SELECT text FROM archive_text WHERE archive = items.archive), ''), ?, ?
            FROM items WHERE items.key = ?
            """, arguments: [docText, keywords, key])
    }

    private static func refreshFTS(source: String, _ db: Database) throws {
        let keys = try Int64.fetchAll(
            db, sql: "SELECT key FROM items WHERE COALESCE(file, archive) = ?", arguments: [source])
        for key in keys { try refreshFTS(key: key, db) }
    }

    private static func domain(of url: URL?) -> String? {
        guard var host = url?.host, !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
}
