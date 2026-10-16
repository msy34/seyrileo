import Foundation
import GRDB

/// Source configuration in the database (replaces the Milestone 1 JSON file).
/// Synchronous by protocol; callers run it off the main actor.
public struct DatabaseSourceStore: SourceStore {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func loadSources() throws -> [ProviderSource] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM source ORDER BY position, createdAt").compactMap(Self.source)
        }
    }

    /// Replaces the source list. Sources missing from `sources` are deleted together with
    /// everything they own (catalogue, favorites, recents, preferences, search rows).
    public func saveSources(_ sources: [ProviderSource]) throws {
        try database.writer.write { db in
            let keep = Set(sources.map(\.id.uuidString))
            let existing = try String.fetchAll(db, sql: "SELECT id FROM source")
            for id in existing where !keep.contains(id) {
                try AppDatabase.deleteSearchRows(db, sourceID: id)
                try db.execute(sql: "DELETE FROM source WHERE id = ?", arguments: [id])
            }
            for (index, source) in sources.enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO source (id, name, kind, serverURL, createdAt, position) VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET name = excluded.name, kind = excluded.kind,
                            serverURL = excluded.serverURL, position = excluded.position
                        """,
                    arguments: [
                        source.id.uuidString, source.name, source.kind.rawValue, source.serverURL.absoluteString,
                        source.createdAt.timeIntervalSince1970, index,
                    ])
            }
        }
    }

    /// One-time import of the Milestone 1 `sources.json`. Idempotent: existing rows are kept,
    /// and the file is renamed to `sources.json.imported` (it never contained secrets).
    @discardableResult
    public func importLegacyJSON(at fileURL: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return 0 }
        let legacy = try FileSourceStore(fileURL: fileURL).loadSources()
        let current = try loadSources()
        let known = Set(current.map(\.id))
        let missing = legacy.filter { !known.contains($0.id) }
        if !missing.isEmpty { try saveSources(current + missing) }
        let imported = fileURL.appendingPathExtension("imported")
        try? FileManager.default.removeItem(at: imported)
        try FileManager.default.moveItem(at: fileURL, to: imported)
        return missing.count
    }

    static func source(_ row: Row) -> ProviderSource? {
        guard let id = UUID(uuidString: row["id"]), let kind = ProviderSource.Kind(rawValue: row["kind"]),
              let url = URL(string: row["serverURL"])
        else { return nil }
        return ProviderSource(
            id: id, name: row["name"], kind: kind, serverURL: url,
            createdAt: Date(timeIntervalSince1970: row["createdAt"]))
    }
}
