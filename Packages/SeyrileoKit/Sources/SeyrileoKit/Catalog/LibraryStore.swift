import Foundation
import GRDB

public struct FavoriteEntry: Identifiable, Hashable, Sendable {
    public let key: MediaKey
    public let title: String
    /// nil when the provider no longer lists this item; it stays favorited but unplayable.
    public let channel: LiveChannel?
    public var id: MediaKey { key }
    public var isAvailable: Bool { channel != nil }
}

public struct RecentEntry: Identifiable, Hashable, Sendable {
    public let key: MediaKey
    public let title: String
    public let playedAt: Date
    public let channel: LiveChannel?
    public var id: MediaKey { key }
    public var isAvailable: Bool { channel != nil }
}

/// The user's own data: favorites (with personal order), recently played and per-source
/// preferences. Keyed by `MediaKey`, independent of catalogue refreshes.
public struct LibraryStore: Sendable {
    public static let recentLimit = 50
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    // MARK: - Favorites

    /// Returns the new favorite state.
    @discardableResult
    public func toggleFavorite(_ key: MediaKey, title: String, now: Date = Date()) async throws -> Bool {
        try await database.writer.write { db in
            let args: StatementArguments = [key.providerID.uuidString, key.kind.rawValue, key.remoteID]
            if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM favorite WHERE sourceID = ? AND kind = ? AND remoteID = ?)", arguments: args) == true {
                try db.execute(sql: "DELETE FROM favorite WHERE sourceID = ? AND kind = ? AND remoteID = ?", arguments: args)
                return false
            }
            let next = (try Double.fetchOne(db, sql: "SELECT MAX(position) FROM favorite WHERE sourceID = ?", arguments: [key.providerID.uuidString]) ?? 0) + 1
            try db.execute(
                sql: "INSERT INTO favorite (sourceID, kind, remoteID, titleSnapshot, position, createdAt) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [key.providerID.uuidString, key.kind.rawValue, key.remoteID, title, next, now.timeIntervalSince1970])
            return true
        }
    }

    public func favoriteKeys(sourceID: UUID) async throws -> Set<MediaKey> {
        try await database.writer.read { db in
            Set(try Row.fetchAll(db, sql: "SELECT kind, remoteID FROM favorite WHERE sourceID = ?", arguments: [sourceID.uuidString])
                .compactMap { row in
                    MediaKind(rawValue: row["kind"]).map { MediaKey(providerID: sourceID, kind: $0, remoteID: row["remoteID"]) }
                })
        }
    }

    public func favorites(sourceID: UUID) async throws -> [FavoriteEntry] {
        try await database.writer.read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM favorite WHERE sourceID = ? ORDER BY position, createdAt",
                arguments: [sourceID.uuidString]
            ).compactMap { row in
                guard let kind = MediaKind(rawValue: row["kind"]) else { return nil }
                let key = MediaKey(providerID: sourceID, kind: kind, remoteID: row["remoteID"])
                return FavoriteEntry(key: key, title: row["titleSnapshot"], channel: try Self.liveChannel(key, db: db))
            }
        }
    }

    /// Persists a personal order: `orderedKeys` is the full favorites list in the new order.
    public func reorderFavorites(sourceID: UUID, orderedKeys: [MediaKey]) async throws {
        try await database.writer.write { db in
            for (index, key) in orderedKeys.enumerated() where key.providerID == sourceID {
                try db.execute(
                    sql: "UPDATE favorite SET position = ? WHERE sourceID = ? AND kind = ? AND remoteID = ?",
                    arguments: [Double(index), sourceID.uuidString, key.kind.rawValue, key.remoteID])
            }
        }
    }

    // MARK: - Recents

    /// Call only when playback actually started. Keeps the newest `recentLimit` per source.
    public func recordPlayed(_ key: MediaKey, title: String, at date: Date = Date()) async throws {
        try await database.writer.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM source WHERE id = ?)", arguments: [key.providerID.uuidString]) == true
            else { return }
            try db.execute(
                sql: """
                    INSERT INTO recent (sourceID, kind, remoteID, titleSnapshot, playedAt) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(sourceID, kind, remoteID) DO UPDATE SET playedAt = excluded.playedAt,
                        titleSnapshot = excluded.titleSnapshot
                    """,
                arguments: [key.providerID.uuidString, key.kind.rawValue, key.remoteID, title, date.timeIntervalSince1970])
            try db.execute(
                sql: """
                    DELETE FROM recent WHERE sourceID = ? AND rowid NOT IN
                        (SELECT rowid FROM recent WHERE sourceID = ? ORDER BY playedAt DESC LIMIT ?)
                    """,
                arguments: [key.providerID.uuidString, key.providerID.uuidString, Self.recentLimit])
        }
    }

    public func recents(sourceID: UUID, limit: Int = 20) async throws -> [RecentEntry] {
        try await database.writer.read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM recent WHERE sourceID = ? ORDER BY playedAt DESC LIMIT ?",
                arguments: [sourceID.uuidString, limit]
            ).compactMap { row in
                guard let kind = MediaKind(rawValue: row["kind"]) else { return nil }
                let key = MediaKey(providerID: sourceID, kind: kind, remoteID: row["remoteID"])
                return RecentEntry(
                    key: key, title: row["titleSnapshot"], playedAt: Date(timeIntervalSince1970: row["playedAt"]),
                    channel: try Self.liveChannel(key, db: db))
            }
        }
    }

    // MARK: - Preferences

    public func setPreference(_ value: String?, forKey key: String, sourceID: UUID) async throws {
        try await database.writer.write { db in
            if let value {
                try db.execute(
                    sql: """
                        INSERT INTO sourcePreference (sourceID, key, value) VALUES (?, ?, ?)
                        ON CONFLICT(sourceID, key) DO UPDATE SET value = excluded.value
                        """,
                    arguments: [sourceID.uuidString, key, value])
            } else {
                try db.execute(sql: "DELETE FROM sourcePreference WHERE sourceID = ? AND key = ?", arguments: [sourceID.uuidString, key])
            }
        }
    }

    public func preference(forKey key: String, sourceID: UUID) async throws -> String? {
        try await database.writer.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM sourcePreference WHERE sourceID = ? AND key = ?", arguments: [sourceID.uuidString, key])
        }
    }

    private static func liveChannel(_ key: MediaKey, db: Database) throws -> LiveChannel? {
        guard key.kind == .live else { return nil }
        return try Row.fetchOne(
            db, sql: "SELECT * FROM liveChannel WHERE sourceID = ? AND remoteID = ?",
            arguments: [key.providerID.uuidString, key.remoteID]
        ).map { CatalogStore.channel($0, sourceID: key.providerID, db: db) }
    }
}
