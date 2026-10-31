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
}

public struct LibraryCounts: Equatable, Sendable {
    public var all = 0, unsorted = 0, favorites = 0, highlights = 0
    public var byType: [ItemType: Int] = [:]
    /// Nested counts roll up into every ancestor.
    public var byCollection: [CollectionPath: Int] = [:]
}

/// Rebuildable SQLite index of the Markdown library. Written by the app, opened read-only by the share extension.
public final class LibraryIndex: Sendable {
    private let pool: DatabasePool

    public init(path: URL, readOnly: Bool = false) throws {
        var config = Configuration()
        config.readonly = readOnly
        pool = try DatabasePool(path: path.path, configuration: config)
        if !readOnly { try Self.migrator.migrate(pool) }
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "items") { t in
                t.primaryKey("id", .text)
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
                t.column("item_id", .text).notNull().references("items", onDelete: .cascade)
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
            let rowids = try Int64.fetchAll(db, sql: "SELECT rowid FROM items WHERE archive = ?", arguments: [path])
            for rowid in rowids { try Self.refreshFTS(rowid: rowid, db) }
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

    public func search(_ query: LibraryQuery) throws -> [IndexedItem] {
        try pool.read { db in
            var sql = "SELECT items.* FROM items"
            var conditions: [String] = []
            var args = StatementArguments()

            if let match = Self.ftsExpression(query.text) {
                sql += " JOIN items_fts ON items_fts.rowid = items.rowid"
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
                    args += [name, name.count + 1, name + "/"]
                }
            }
            if let tag = query.tag {
                conditions.append("EXISTS (SELECT 1 FROM item_tags WHERE item_id = items.id AND tag = ? COLLATE NOCASE)")
                args += [tag]
            }
            if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
            sql += " ORDER BY items.created DESC, items.id"

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
                SELECT COUNT(*) AS n, COALESCE(SUM(collection = 'Unsorted'), 0) AS u,
                       COALESCE(SUM(favorite), 0) AS f, COALESCE(SUM(has_highlights), 0) AS h FROM items
                """)!
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
        for (position, tag) in item.tags.enumerated() {
            try db.execute(
                sql: "INSERT INTO item_tags(item_id, tag, position) VALUES (?, ?, ?)", arguments: [id, tag, position])
        }
        try refreshFTS(rowid: db.lastInsertedRowID, db)
    }

    private static func delete(_ id: ItemID, _ db: Database) throws {
        if let rowid = try Int64.fetchOne(db, sql: "SELECT rowid FROM items WHERE id = ?", arguments: [id.relativePath]) {
            try db.execute(sql: "DELETE FROM items_fts WHERE rowid = ?", arguments: [rowid])
        }
        try db.execute(sql: "DELETE FROM item_tags WHERE item_id = ?", arguments: [id.relativePath])
        try db.execute(sql: "DELETE FROM items WHERE id = ?", arguments: [id.relativePath])
    }

    private static func refreshFTS(rowid: Int64, _ db: Database) throws {
        try db.execute(sql: "DELETE FROM items_fts WHERE rowid = ?", arguments: [rowid])
        try db.execute(sql: """
            INSERT INTO items_fts(rowid, title, note, description, url, highlights, archive_text)
            SELECT items.rowid, items.title, items.note, COALESCE(items.description, ''), COALESCE(items.url, ''),
                   items.highlights, COALESCE((SELECT text FROM archive_text WHERE archive = items.archive), '')
            FROM items WHERE items.rowid = ?
            """, arguments: [rowid])
    }

    private static func domain(of url: URL?) -> String? {
        guard var host = url?.host, !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
}
