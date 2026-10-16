import Foundation
import GRDB

/// A personal collection ("Evening sports") of one source.
public struct UserCollection: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let sourceID: UUID
    public let name: String
    public let itemCount: Int
}

/// One item of a collection. `title` is the name when it was added, kept so the item can
/// still be listed after the provider removes it.
public struct CollectionEntry: Identifiable, Hashable, Sendable {
    public let key: MediaKey
    public let title: String
    /// Set for live channels the provider still lists.
    public let channel: LiveChannel?
    /// false when the provider no longer lists the item.
    public let isAvailable: Bool
    public var id: MediaKey { key }
}

public enum OrganizationError: Error, Equatable, Sendable {
    case emptyName
    case nameTooLong
    case collectionNotFound
}

/// The user's own organization of a source: local channel aliases, hidden channels and
/// categories, personal order, and collections. Everything is keyed by source + provider ID so
/// it survives catalogue refreshes, and is removed with the source.
public struct OrganizationStore: Sendable {
    public static let maxNameLength = 80
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    static func cleanName(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard trimmed.count <= maxNameLength else { throw OrganizationError.nameTooLong }
        return trimmed
    }

    // MARK: - Channel alias and visibility

    /// Sets (or with nil/blank, clears) the local name. The provider's name is never changed.
    public func setAlias(_ alias: String?, for key: MediaKey) async throws {
        let alias = try Self.cleanName(alias)
        try await database.writer.write { db in
            let sid = key.providerID.uuidString
            try db.execute(
                sql: """
                    INSERT INTO channelOverride (sourceID, remoteID, alias) VALUES (?, ?, ?)
                    ON CONFLICT(sourceID, remoteID) DO UPDATE SET alias = excluded.alias
                    """,
                arguments: [sid, key.remoteID, alias])
            try db.execute(sql: "DELETE FROM channelAliasSearch WHERE sourceID = ? AND remoteID = ?", arguments: [sid, key.remoteID])
            if let alias {
                try db.execute(
                    sql: "INSERT INTO channelAliasSearch (searchName, sourceID, remoteID) VALUES (?, ?, ?)",
                    arguments: [SearchText.normalize(alias), sid, key.remoteID])
            }
            try Self.pruneOverride(db, sourceID: sid, remoteID: key.remoteID)
        }
    }

    public func setHidden(_ hidden: Bool, channel key: MediaKey) async throws {
        try await database.writer.write { db in
            let sid = key.providerID.uuidString
            try db.execute(
                sql: """
                    INSERT INTO channelOverride (sourceID, remoteID, hidden) VALUES (?, ?, ?)
                    ON CONFLICT(sourceID, remoteID) DO UPDATE SET hidden = excluded.hidden
                    """,
                arguments: [sid, key.remoteID, hidden])
            try Self.pruneOverride(db, sourceID: sid, remoteID: key.remoteID)
        }
    }

    private static func pruneOverride(_ db: Database, sourceID: String, remoteID: String) throws {
        try db.execute(
            sql: "DELETE FROM channelOverride WHERE sourceID = ? AND remoteID = ? AND alias IS NULL AND hidden = 0",
            arguments: [sourceID, remoteID])
    }

    // MARK: - Order

    /// Stores the user's order for one category. `orderedRemoteIDs` is the full visible list
    /// in its new order; hidden channels keep their relative place after it.
    public func setChannelOrder(sourceID: UUID, categoryID: String, orderedRemoteIDs: [String]) async throws {
        try await database.writer.write { db in
            let sid = sourceID.uuidString
            try db.execute(sql: "DELETE FROM channelOrder WHERE sourceID = ? AND categoryRemoteID = ?", arguments: [sid, categoryID])
            let insert = try db.cachedStatement(
                sql: "INSERT OR IGNORE INTO channelOrder (sourceID, categoryRemoteID, channelRemoteID, position) VALUES (?, ?, ?, ?)")
            for (index, remoteID) in orderedRemoteIDs.enumerated() {
                try insert.execute(arguments: [sid, categoryID, remoteID, index])
            }
        }
    }

    public func resetChannelOrder(sourceID: UUID, categoryID: String) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "DELETE FROM channelOrder WHERE sourceID = ? AND categoryRemoteID = ?",
                arguments: [sourceID.uuidString, categoryID])
        }
    }

    public func hasCustomChannelOrder(sourceID: UUID, categoryID: String) async throws -> Bool {
        try await database.writer.read { db in
            try Bool.fetchOne(
                db, sql: "SELECT EXISTS(SELECT 1 FROM channelOrder WHERE sourceID = ? AND categoryRemoteID = ?)",
                arguments: [sourceID.uuidString, categoryID]) ?? false
        }
    }

    /// Stores the user's category order (`orderedRemoteIDs` = the visible list in new order).
    public func setCategoryOrder(sourceID: UUID, orderedRemoteIDs: [String]) async throws {
        try await database.writer.write { db in
            let sid = sourceID.uuidString
            try db.execute(sql: "UPDATE categoryOverride SET position = NULL WHERE sourceID = ?", arguments: [sid])
            for (index, remoteID) in orderedRemoteIDs.enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO categoryOverride (sourceID, remoteID, position) VALUES (?, ?, ?)
                        ON CONFLICT(sourceID, remoteID) DO UPDATE SET position = excluded.position
                        """,
                    arguments: [sid, remoteID, index])
            }
            try db.execute(sql: "DELETE FROM categoryOverride WHERE sourceID = ? AND hidden = 0 AND position IS NULL", arguments: [sid])
        }
    }

    public func resetCategoryOrder(sourceID: UUID) async throws {
        try await database.writer.write { db in
            let sid = sourceID.uuidString
            try db.execute(sql: "UPDATE categoryOverride SET position = NULL WHERE sourceID = ?", arguments: [sid])
            try db.execute(sql: "DELETE FROM categoryOverride WHERE sourceID = ? AND hidden = 0", arguments: [sid])
        }
    }

    public func setHidden(_ hidden: Bool, categoryID: String, sourceID: UUID) async throws {
        try await database.writer.write { db in
            let sid = sourceID.uuidString
            try db.execute(
                sql: """
                    INSERT INTO categoryOverride (sourceID, remoteID, hidden) VALUES (?, ?, ?)
                    ON CONFLICT(sourceID, remoteID) DO UPDATE SET hidden = excluded.hidden
                    """,
                arguments: [sid, categoryID, hidden])
            try db.execute(
                sql: "DELETE FROM categoryOverride WHERE sourceID = ? AND remoteID = ? AND hidden = 0 AND position IS NULL",
                arguments: [sid, categoryID])
        }
    }

    // MARK: - Collections

    public func collections(sourceID: UUID) async throws -> [UserCollection] {
        try await database.writer.read { db in
            try Row.fetchAll(
                db, sql: """
                    SELECT c.id, c.name, (SELECT COUNT(*) FROM collectionItem i WHERE i.collectionID = c.id) AS itemCount
                    FROM userCollection c WHERE c.sourceID = ? ORDER BY c.position, c.createdAt
                    """,
                arguments: [sourceID.uuidString]
            ).compactMap { row in
                guard let id = UUID(uuidString: row["id"]) else { return nil }
                return UserCollection(id: id, sourceID: sourceID, name: row["name"], itemCount: row["itemCount"])
            }
        }
    }

    @discardableResult
    public func createCollection(named name: String, sourceID: UUID, now: Date = Date()) async throws -> UserCollection {
        guard let name = try Self.cleanName(name) else { throw OrganizationError.emptyName }
        let id = UUID()
        try await database.writer.write { db in
            let next = (try Double.fetchOne(db, sql: "SELECT MAX(position) FROM userCollection WHERE sourceID = ?", arguments: [sourceID.uuidString]) ?? 0) + 1
            try db.execute(
                sql: "INSERT INTO userCollection (id, sourceID, name, position, createdAt) VALUES (?, ?, ?, ?, ?)",
                arguments: [id.uuidString, sourceID.uuidString, name, next, now.timeIntervalSince1970])
        }
        return UserCollection(id: id, sourceID: sourceID, name: name, itemCount: 0)
    }

    public func renameCollection(_ id: UUID, to name: String) async throws {
        guard let name = try Self.cleanName(name) else { throw OrganizationError.emptyName }
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE userCollection SET name = ? WHERE id = ?", arguments: [name, id.uuidString])
            guard db.changesCount > 0 else { throw OrganizationError.collectionNotFound }
        }
    }

    public func deleteCollection(_ id: UUID) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM userCollection WHERE id = ?", arguments: [id.uuidString])
        }
    }

    public func reorderCollections(sourceID: UUID, orderedIDs: [UUID]) async throws {
        try await database.writer.write { db in
            for (index, id) in orderedIDs.enumerated() {
                try db.execute(
                    sql: "UPDATE userCollection SET position = ? WHERE id = ? AND sourceID = ?",
                    arguments: [Double(index), id.uuidString, sourceID.uuidString])
            }
        }
    }

    /// Adds an item at the end. Items must belong to the collection's source.
    public func add(_ key: MediaKey, title: String, to collectionID: UUID, now: Date = Date()) async throws {
        try await database.writer.write { db in
            guard let owner = try String.fetchOne(db, sql: "SELECT sourceID FROM userCollection WHERE id = ?", arguments: [collectionID.uuidString]),
                  owner == key.providerID.uuidString
            else { throw OrganizationError.collectionNotFound }
            let next = (try Double.fetchOne(db, sql: "SELECT MAX(position) FROM collectionItem WHERE collectionID = ?", arguments: [collectionID.uuidString]) ?? 0) + 1
            try db.execute(
                sql: """
                    INSERT INTO collectionItem (collectionID, kind, remoteID, titleSnapshot, position, addedAt) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(collectionID, kind, remoteID) DO UPDATE SET titleSnapshot = excluded.titleSnapshot
                    """,
                arguments: [collectionID.uuidString, key.kind.rawValue, key.remoteID, title, next, now.timeIntervalSince1970])
        }
    }

    public func remove(_ key: MediaKey, from collectionID: UUID) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "DELETE FROM collectionItem WHERE collectionID = ? AND kind = ? AND remoteID = ?",
                arguments: [collectionID.uuidString, key.kind.rawValue, key.remoteID])
        }
    }

    public func reorderItems(in collectionID: UUID, orderedKeys: [MediaKey]) async throws {
        try await database.writer.write { db in
            for (index, key) in orderedKeys.enumerated() {
                try db.execute(
                    sql: "UPDATE collectionItem SET position = ? WHERE collectionID = ? AND kind = ? AND remoteID = ?",
                    arguments: [Double(index), collectionID.uuidString, key.kind.rawValue, key.remoteID])
            }
        }
    }

    /// IDs of the collections that contain `key`.
    public func collectionIDs(containing key: MediaKey) async throws -> Set<UUID> {
        try await database.writer.read { db in
            Set(try String.fetchAll(
                db, sql: """
                    SELECT i.collectionID FROM collectionItem i JOIN userCollection c ON c.id = i.collectionID
                    WHERE c.sourceID = ? AND i.kind = ? AND i.remoteID = ?
                    """,
                arguments: [key.providerID.uuidString, key.kind.rawValue, key.remoteID]
            ).compactMap(UUID.init(uuidString:)))
        }
    }

    public func items(in collectionID: UUID) async throws -> [CollectionEntry] {
        try await database.writer.read { db in
            guard let owner = try String.fetchOne(db, sql: "SELECT sourceID FROM userCollection WHERE id = ?", arguments: [collectionID.uuidString]),
                  let sourceID = UUID(uuidString: owner)
            else { return [] }
            return try Row.fetchAll(
                db, sql: "SELECT * FROM collectionItem WHERE collectionID = ? ORDER BY position, addedAt",
                arguments: [collectionID.uuidString]
            ).compactMap { row in
                guard let kind = MediaKind(rawValue: row["kind"]) else { return nil }
                let key = MediaKey(providerID: sourceID, kind: kind, remoteID: row["remoteID"])
                let title: String = row["titleSnapshot"]
                switch kind {
                case .live:
                    let channel = try Row.fetchOne(
                        db, sql: "SELECT * FROM liveChannel WHERE sourceID = ? AND remoteID = ?", arguments: [owner, key.remoteID]
                    ).map { CatalogStore.channel($0, sourceID: sourceID, db: db) }
                    return CollectionEntry(key: key, title: channel?.displayName ?? title, channel: channel, isAvailable: channel != nil)
                case .movie, .series:
                    let table = kind == .movie ? "movie" : "series"
                    let name = try String.fetchOne(
                        db, sql: "SELECT name FROM \(table) WHERE sourceID = ? AND remoteID = ?", arguments: [owner, key.remoteID])
                    return CollectionEntry(key: key, title: name ?? title, channel: nil, isAvailable: name != nil)
                case .episode:
                    return CollectionEntry(key: key, title: title, channel: nil, isAvailable: false)
                }
            }
        }
    }
}
