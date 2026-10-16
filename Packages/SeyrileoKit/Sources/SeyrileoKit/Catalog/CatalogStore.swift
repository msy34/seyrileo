import Foundation
import GRDB

public struct CategorySummary: Identifiable, Hashable, Sendable {
    public let category: LiveCategory
    public let channelCount: Int
    public var id: String { category.remoteID }
}

/// Last known refresh state of a source's catalogue.
public struct CatalogStatus: Equatable, Sendable {
    public let lastSuccessAt: Date?
    public let lastAttemptAt: Date?
    /// Machine-readable code of the last failed refresh (nil after a success).
    public let lastErrorCode: String?
    public let account: AccountInfo?
    public let categoryCount: Int
    public let channelCount: Int
    public let droppedCount: Int

    public var hasCatalog: Bool { lastSuccessAt != nil }
}

public struct ChannelSearchResult: Sendable {
    public let channels: [LiveChannel]
    /// More matches exist than were returned.
    public let isTruncated: Bool
}

/// Live catalogue persistence. Refreshes replace a source's catalogue in one transaction:
/// the download happens first, so a failed or cancelled refresh never touches stored data,
/// and a crash mid-write rolls back. User data (favorites, recents, preferences) lives in
/// separate tables and is never modified by a refresh.
public struct CatalogStore: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    // MARK: - Refresh

    public enum RefreshOutcome: Equatable, Sendable {
        case applied(categories: Int, channels: Int)
        case cancelled
    }

    /// Downloads with `fetch`, then applies atomically. Throws the fetch error after recording
    /// it in `catalogState` (existing catalogue untouched). Cancellation records nothing.
    @discardableResult
    public func refresh(
        sourceID: UUID, now: @Sendable () -> Date = Date.init,
        fetch: @Sendable () async throws -> LiveCatalogSnapshot
    ) async throws -> RefreshOutcome {
        let snapshot: LiveCatalogSnapshot
        do {
            snapshot = try await fetch()
            try Task.checkCancellation()
        } catch is CancellationError {
            return .cancelled
        } catch XtreamError.cancelled {
            return .cancelled
        } catch {
            try? await recordFailure(sourceID: sourceID, code: Self.errorCode(error), at: now())
            throw error
        }
        try await apply(snapshot, sourceID: sourceID, at: now())
        return .applied(categories: snapshot.categories.items.count, channels: snapshot.channels.items.count)
    }

    func apply(_ snapshot: LiveCatalogSnapshot, sourceID: UUID, at date: Date) async throws {
        let sid = sourceID.uuidString
        try await database.writer.write { db in
            // Live search rows only: the movie/series index belongs to the library refresh.
            try db.execute(sql: "DELETE FROM liveChannelSearch WHERE sourceID = ?", arguments: [sid])
            try db.execute(sql: "DELETE FROM liveChannelCategory WHERE sourceID = ?", arguments: [sid])
            try db.execute(sql: "DELETE FROM liveChannel WHERE sourceID = ?", arguments: [sid])
            try db.execute(sql: "DELETE FROM liveCategory WHERE sourceID = ?", arguments: [sid])

            let insertCategory = try db.cachedStatement(
                sql: "INSERT OR IGNORE INTO liveCategory (sourceID, remoteID, name, position) VALUES (?, ?, ?, ?)")
            for (index, category) in snapshot.categories.items.enumerated() {
                try insertCategory.execute(arguments: [sid, category.remoteID, category.name, index])
            }

            let insertChannel = try db.cachedStatement(sql: """
                INSERT OR IGNORE INTO liveChannel
                    (sourceID, remoteID, name, searchName, number, iconURL, epgChannelID, advertisesArchive, position)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            let insertSearch = try db.cachedStatement(
                sql: "INSERT INTO liveChannelSearch (searchName, sourceID, remoteID) VALUES (?, ?, ?)")
            let insertMembership = try db.cachedStatement(sql: """
                INSERT OR IGNORE INTO liveChannelCategory (sourceID, categoryRemoteID, channelRemoteID, position)
                VALUES (?, ?, ?, ?)
                """)
            var seen = Set<String>()
            for (index, channel) in snapshot.channels.items.enumerated() {
                let remoteID = channel.key.remoteID
                guard seen.insert(remoteID).inserted else { continue }  // provider duplicates: first wins
                let searchName = SearchText.normalize(channel.name)
                try insertChannel.execute(arguments: [
                    sid, remoteID, channel.name, searchName, channel.number, channel.iconURL?.absoluteString,
                    channel.epgChannelID, channel.advertisesArchive, index,
                ])
                try insertSearch.execute(arguments: [searchName, sid, remoteID])
                for categoryID in channel.categoryIDs {
                    try insertMembership.execute(arguments: [sid, categoryID, remoteID, index])
                }
            }

            let account = snapshot.account
            try db.execute(
                sql: """
                    INSERT INTO catalogState (sourceID, lastSuccessAt, lastAttemptAt, lastErrorCode, accountStatus,
                        accountExpiresAt, activeConnections, maxConnections, allowedFormats, serverTimezone,
                        categoryCount, channelCount, droppedCount)
                    VALUES (?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(sourceID) DO UPDATE SET lastSuccessAt = excluded.lastSuccessAt,
                        lastAttemptAt = excluded.lastAttemptAt, lastErrorCode = NULL,
                        accountStatus = excluded.accountStatus, accountExpiresAt = excluded.accountExpiresAt,
                        activeConnections = excluded.activeConnections, maxConnections = excluded.maxConnections,
                        allowedFormats = excluded.allowedFormats, serverTimezone = excluded.serverTimezone,
                        categoryCount = excluded.categoryCount, channelCount = excluded.channelCount,
                        droppedCount = excluded.droppedCount
                    """,
                arguments: [
                    sid, date.timeIntervalSince1970, date.timeIntervalSince1970, Self.statusCode(account.status),
                    account.expiresAt?.timeIntervalSince1970, account.activeConnections, account.maxConnections,
                    account.allowedOutputFormats.joined(separator: ","), account.serverTimezone,
                    snapshot.categories.items.count, seen.count,
                    snapshot.categories.droppedCount + snapshot.channels.droppedCount,
                ])
        }
    }

    private func recordFailure(sourceID: UUID, code: String, at date: Date) async throws {
        try await database.writer.write { db in
            // Only for an existing source (the row may have been removed meanwhile).
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM source WHERE id = ?)", arguments: [sourceID.uuidString]) == true
            else { return }
            try db.execute(
                sql: """
                    INSERT INTO catalogState (sourceID, lastAttemptAt, lastErrorCode) VALUES (?, ?, ?)
                    ON CONFLICT(sourceID) DO UPDATE SET lastAttemptAt = excluded.lastAttemptAt,
                        lastErrorCode = excluded.lastErrorCode
                    """,
                arguments: [sourceID.uuidString, date.timeIntervalSince1970, code])
        }
    }

    // MARK: - Queries

    public func status(sourceID: UUID) async throws -> CatalogStatus? {
        try await database.writer.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM catalogState WHERE sourceID = ?", arguments: [sourceID.uuidString])
            else { return nil }
            let lastSuccess: Double? = row["lastSuccessAt"]
            let lastAttempt: Double? = row["lastAttemptAt"]
            let statusCode: String? = row["accountStatus"]
            let formats: String = row["allowedFormats"]
            let expires: Double? = row["accountExpiresAt"]
            let account = statusCode.map {
                AccountInfo(
                    status: Self.status(fromCode: $0),
                    expiresAt: expires.map(Date.init(timeIntervalSince1970:)),
                    activeConnections: row["activeConnections"], maxConnections: row["maxConnections"],
                    allowedOutputFormats: formats.isEmpty ? [] : formats.split(separator: ",").map(String.init),
                    serverTimezone: row["serverTimezone"])
            }
            return CatalogStatus(
                lastSuccessAt: lastSuccess.map(Date.init(timeIntervalSince1970:)),
                lastAttemptAt: lastAttempt.map(Date.init(timeIntervalSince1970:)),
                lastErrorCode: row["lastErrorCode"], account: account,
                categoryCount: row["categoryCount"], channelCount: row["channelCount"], droppedCount: row["droppedCount"])
        }
    }

    /// Categories in the user's order (provider order for the rest). Hidden ones only when asked.
    public func categories(sourceID: UUID, includeHidden: Bool = false) async throws -> [CategorySummary] {
        try await database.writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT c.remoteID, c.name, COALESCE(o.hidden, 0) AS hidden,
                        (SELECT COUNT(*) FROM liveChannelCategory m WHERE m.sourceID = c.sourceID AND m.categoryRemoteID = c.remoteID) AS channelCount
                    FROM liveCategory c
                    LEFT JOIN categoryOverride o ON o.sourceID = c.sourceID AND o.remoteID = c.remoteID
                    WHERE c.sourceID = ? AND (? OR COALESCE(o.hidden, 0) = 0)
                    ORDER BY o.position IS NULL, o.position, c.position
                    """,
                arguments: [sourceID.uuidString, includeHidden]
            ).map { row in
                CategorySummary(
                    category: LiveCategory(providerID: sourceID, remoteID: row["remoteID"], name: row["name"], isHidden: row["hidden"]),
                    channelCount: row["channelCount"])
            }
        }
    }

    /// Channels of a category in the user's order; channels without a personal position follow
    /// in provider order (so new channels appear at the end). Hidden ones only when asked.
    public func channels(sourceID: UUID, categoryID: String, includeHidden: Bool = false) async throws -> [LiveChannel] {
        try await database.writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT ch.*, ov.alias AS overrideAlias, COALESCE(ov.hidden, 0) AS overrideHidden
                    FROM liveChannelCategory m
                    JOIN liveChannel ch ON ch.sourceID = m.sourceID AND ch.remoteID = m.channelRemoteID
                    LEFT JOIN channelOverride ov ON ov.sourceID = ch.sourceID AND ov.remoteID = ch.remoteID
                    LEFT JOIN channelOrder o ON o.sourceID = m.sourceID AND o.categoryRemoteID = m.categoryRemoteID
                        AND o.channelRemoteID = m.channelRemoteID
                    WHERE m.sourceID = ? AND m.categoryRemoteID = ? AND (? OR COALESCE(ov.hidden, 0) = 0)
                    ORDER BY o.position IS NULL, o.position, m.position
                    """,
                arguments: [sourceID.uuidString, categoryID, includeHidden]
            ).map { Self.channel($0, sourceID: sourceID, db: db) }
        }
    }

    public func channel(_ key: MediaKey) async throws -> LiveChannel? {
        guard key.kind == .live else { return nil }
        return try await database.writer.read { db in
            try Row.fetchOne(
                db, sql: "SELECT ch.*, \(Self.overrideColumns) FROM liveChannel ch \(Self.overrideJoin) WHERE ch.sourceID = ? AND ch.remoteID = ?",
                arguments: [key.providerID.uuidString, key.remoteID]
            ).map { Self.channel($0, sourceID: key.providerID, db: db) }
        }
    }

    /// Visible channels that the provider maps to guide data (non-empty EPG id), in provider order.
    public func channelsWithGuide(sourceID: UUID) async throws -> [LiveChannel] {
        try await database.writer.read { db in
            try Row.fetchAll(
                db, sql: """
                    SELECT ch.*, \(Self.overrideColumns) FROM liveChannel ch \(Self.overrideJoin)
                    WHERE ch.sourceID = ? AND ch.epgChannelID IS NOT NULL AND ch.epgChannelID != ''
                        AND COALESCE(ov.hidden, 0) = 0
                    ORDER BY ch.position
                    """,
                arguments: [sourceID.uuidString]
            ).map { Self.channel($0, sourceID: sourceID, db: db) }
        }
    }

    /// Channels the user hid, for the "Hidden" management screen.
    public func hiddenChannels(sourceID: UUID) async throws -> [LiveChannel] {
        try await database.writer.read { db in
            try Row.fetchAll(
                db, sql: """
                    SELECT ch.*, \(Self.overrideColumns) FROM liveChannel ch \(Self.overrideJoin)
                    WHERE ch.sourceID = ? AND ov.hidden = 1 ORDER BY ch.position
                    """,
                arguments: [sourceID.uuidString]
            ).map { Self.channel($0, sourceID: sourceID, db: db) }
        }
    }

    /// Indexed (FTS5) word-prefix search within one source, optionally within one category.
    /// Matches the provider name and the user's alias; hidden channels are left out.
    public func search(
        sourceID: UUID, query: String, categoryID: String? = nil, limit: Int = 200
    ) async throws -> ChannelSearchResult {
        guard let match = SearchText.ftsPrefixQuery(query) else { return ChannelSearchResult(channels: [], isTruncated: false) }
        return try await database.writer.read { db in
            var sql = """
                SELECT ch.*, \(Self.overrideColumns) FROM liveChannel ch \(Self.overrideJoin)
                WHERE ch.sourceID = ? AND COALESCE(ov.hidden, 0) = 0 AND ch.remoteID IN (
                    SELECT remoteID FROM liveChannelSearch WHERE liveChannelSearch MATCH ? AND sourceID = ?
                    UNION
                    SELECT remoteID FROM channelAliasSearch WHERE channelAliasSearch MATCH ? AND sourceID = ?)
                """
            var arguments: StatementArguments = [sourceID.uuidString, match, sourceID.uuidString, match, sourceID.uuidString]
            if let categoryID {
                sql += """
                     AND EXISTS (SELECT 1 FROM liveChannelCategory m WHERE m.sourceID = ch.sourceID
                        AND m.channelRemoteID = ch.remoteID AND m.categoryRemoteID = ?)
                    """
                arguments += [categoryID]
            }
            sql += " ORDER BY ch.position LIMIT ?"
            arguments += [limit + 1]
            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            return ChannelSearchResult(
                channels: rows.prefix(limit).map { Self.channel($0, sourceID: sourceID, db: db) },
                isTruncated: rows.count > limit)
        }
    }

    // MARK: - Mapping

    static let overrideColumns = "ov.alias AS overrideAlias, COALESCE(ov.hidden, 0) AS overrideHidden"
    static let overrideJoin = "LEFT JOIN channelOverride ov ON ov.sourceID = ch.sourceID AND ov.remoteID = ch.remoteID"

    /// Maps a `liveChannel` row. Rows selected with `overrideColumns` carry the user's alias and
    /// hidden flag; plain rows are looked up so every caller sees the same personal data.
    static func channel(_ row: Row, sourceID: UUID, db: Database) -> LiveChannel {
        let remoteID: String = row["remoteID"]
        let categoryIDs = (try? String.fetchAll(
            db, sql: "SELECT categoryRemoteID FROM liveChannelCategory WHERE sourceID = ? AND channelRemoteID = ?",
            arguments: [sourceID.uuidString, remoteID])) ?? []
        let icon: String? = row["iconURL"]
        let alias: String?
        let hidden: Bool
        if row.hasColumn("overrideHidden") {
            alias = row["overrideAlias"]
            hidden = row["overrideHidden"]
        } else {
            let override = try? Row.fetchOne(
                db, sql: "SELECT alias, hidden FROM channelOverride WHERE sourceID = ? AND remoteID = ?",
                arguments: [sourceID.uuidString, remoteID])
            alias = override?["alias"]
            hidden = override?["hidden"] ?? false
        }
        return LiveChannel(
            key: MediaKey(providerID: sourceID, kind: .live, remoteID: remoteID),
            name: row["name"], number: row["number"], categoryIDs: categoryIDs,
            iconURL: icon.flatMap(URL.init(string:)), epgChannelID: row["epgChannelID"],
            advertisesArchive: row["advertisesArchive"], alias: alias, isHidden: hidden)
    }

    static func statusCode(_ status: AccountInfo.Status) -> String {
        switch status {
        case .active: "active"
        case .expired: "expired"
        case .banned: "banned"
        case .disabled: "disabled"
        case .unknown(let raw): "unknown:" + (raw ?? "")
        }
    }

    static func status(fromCode code: String) -> AccountInfo.Status {
        if code.hasPrefix("unknown:") {
            let raw = String(code.dropFirst("unknown:".count))
            return .unknown(raw.isEmpty ? nil : raw)
        }
        return AccountInfo.Status(raw: code)
    }

    /// Stable, secret-free code for the last refresh error (shown via `UserIssue` mapping).
    static func errorCode(_ error: Error) -> String {
        switch error {
        case let error as XtreamError: "xtream:\(error)"
        case is SourceAccessErrorMarker: "credentials"
        default: "other:\(type(of: error))"
        }
    }
}

/// Lets app-level "credentials missing" errors be coded without a dependency on the app.
public protocol SourceAccessErrorMarker: Error {}
