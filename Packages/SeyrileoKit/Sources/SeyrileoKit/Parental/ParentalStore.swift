import Foundation
import GRDB

/// What can be locked: a whole category of one kind, or a single channel, movie or series.
public enum LockScope: String, Codable, Sendable, CaseIterable {
    case liveCategory, movieCategory, seriesCategory
    case live, movie, series

    public static func category(for kind: MediaKind) -> LockScope? {
        switch kind {
        case .live: .liveCategory
        case .movie: .movieCategory
        case .series: .seriesCategory
        case .episode: nil
        }
    }

    public static func item(for kind: MediaKind) -> LockScope? {
        switch kind {
        case .live: .live
        case .movie: .movie
        case .series: .series
        case .episode: nil
        }
    }
}

/// The locked content of one source, loaded once and checked in memory.
public struct LockSet: Equatable, Sendable {
    public var entries: Set<Entry> = []

    public struct Entry: Hashable, Sendable {
        public let scope: LockScope
        public let remoteID: String
    }

    public init(entries: Set<Entry> = []) {
        self.entries = entries
    }

    public var isEmpty: Bool { entries.isEmpty }

    public func contains(_ scope: LockScope, _ remoteID: String) -> Bool {
        entries.contains(Entry(scope: scope, remoteID: remoteID))
    }

    public func isCategoryLocked(_ kind: MediaKind, _ categoryID: String) -> Bool {
        LockScope.category(for: kind).map { contains($0, categoryID) } ?? false
    }

    /// An item is restricted when it, or any category it belongs to, is locked. An episode is
    /// restricted through its series (`seriesKey`) and that series' categories.
    public func isLocked(_ key: MediaKey, categoryIDs: [String], seriesKey: MediaKey? = nil) -> Bool {
        let kind = key.kind == .episode ? MediaKind.series : key.kind
        let remoteID = key.kind == .episode ? (seriesKey?.remoteID ?? "") : key.remoteID
        if let scope = LockScope.item(for: kind), contains(scope, remoteID) { return true }
        return categoryIDs.contains { isCategoryLocked(kind, $0) }
    }
}

public struct ParentalStore: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func lockSet(sourceID: UUID) async throws -> LockSet {
        try await database.writer.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT scope, remoteID FROM lockedContent WHERE sourceID = ?", arguments: [sourceID.uuidString])
            return LockSet(entries: Set(rows.compactMap { row in
                LockScope(rawValue: row["scope"]).map { LockSet.Entry(scope: $0, remoteID: row["remoteID"]) }
            }))
        }
    }

    public func setLocked(_ locked: Bool, scope: LockScope, remoteID: String, sourceID: UUID) async throws {
        try await database.writer.write { db in
            if locked {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO lockedContent (sourceID, scope, remoteID) VALUES (?, ?, ?)",
                    arguments: [sourceID.uuidString, scope.rawValue, remoteID])
            } else {
                try db.execute(
                    sql: "DELETE FROM lockedContent WHERE sourceID = ? AND scope = ? AND remoteID = ?",
                    arguments: [sourceID.uuidString, scope.rawValue, remoteID])
            }
        }
    }
}
