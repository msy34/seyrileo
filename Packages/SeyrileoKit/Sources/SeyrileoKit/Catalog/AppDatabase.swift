import Foundation
import GRDB

/// The on-device database: sources, live catalogue, favorites, recents and preferences.
///
/// All catalogue rows are namespaced by source UUID; removing a source cascades to everything
/// it owns. Credentials are never stored here (Keychain only).
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// WAL database pool: reads never block on writes, and nothing runs on the main thread
    /// unless a caller explicitly does so.
    public static func onDisk(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.label = "catalog"
        return try AppDatabase(DatabasePool(path: url.path, configuration: configuration))
    }

    public static func inMemory() throws -> AppDatabase {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        return try AppDatabase(DatabaseQueue(configuration: configuration))
    }

    /// Application Support/Catalog/catalog.sqlite (brand-neutral on purpose).
    public static func defaultLocation() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("Catalog", isDirectory: true).appendingPathComponent("catalog.sqlite")
    }

    static let migrationIdentifiers = ["v1-catalog", "v2-library", "v3-organization", "v4-parental"]

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-catalog") { db in
            try db.execute(sql: """
                CREATE TABLE source (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    serverURL TEXT NOT NULL,
                    createdAt DOUBLE NOT NULL,
                    position INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE catalogState (
                    sourceID TEXT PRIMARY KEY NOT NULL REFERENCES source(id) ON DELETE CASCADE,
                    lastSuccessAt DOUBLE,
                    lastAttemptAt DOUBLE,
                    lastErrorCode TEXT,
                    accountStatus TEXT,
                    accountExpiresAt DOUBLE,
                    activeConnections INTEGER,
                    maxConnections INTEGER,
                    allowedFormats TEXT NOT NULL DEFAULT '',
                    serverTimezone TEXT,
                    categoryCount INTEGER NOT NULL DEFAULT 0,
                    channelCount INTEGER NOT NULL DEFAULT 0,
                    droppedCount INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE liveCategory (
                    sourceID TEXT NOT NULL REFERENCES source(id) ON DELETE CASCADE,
                    remoteID TEXT NOT NULL,
                    name TEXT NOT NULL,
                    position INTEGER NOT NULL,
                    PRIMARY KEY (sourceID, remoteID)
                );
                CREATE TABLE liveChannel (
                    sourceID TEXT NOT NULL REFERENCES source(id) ON DELETE CASCADE,
                    remoteID TEXT NOT NULL,
                    name TEXT NOT NULL,
                    searchName TEXT NOT NULL,
                    number INTEGER,
                    iconURL TEXT,
                    epgChannelID TEXT,
                    advertisesArchive BOOLEAN NOT NULL DEFAULT 0,
                    position INTEGER NOT NULL,
                    PRIMARY KEY (sourceID, remoteID)
                );
                CREATE INDEX liveChannel_source_position ON liveChannel(sourceID, position);
                CREATE TABLE liveChannelCategory (
                    sourceID TEXT NOT NULL,
                    categoryRemoteID TEXT NOT NULL,
                    channelRemoteID TEXT NOT NULL,
                    position INTEGER NOT NULL,
                    PRIMARY KEY (sourceID, categoryRemoteID, channelRemoteID),
                    FOREIGN KEY (sourceID, channelRemoteID) REFERENCES liveChannel(sourceID, remoteID) ON DELETE CASCADE
                );
                CREATE INDEX liveChannelCategory_channel ON liveChannelCategory(sourceID, channelRemoteID);
                CREATE VIRTUAL TABLE liveChannelSearch USING fts5(
                    searchName, sourceID UNINDEXED, remoteID UNINDEXED, tokenize = 'unicode61'
                );
                CREATE TABLE favorite (
                    sourceID TEXT NOT NULL REFERENCES source(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL,
                    remoteID TEXT NOT NULL,
                    titleSnapshot TEXT NOT NULL,
                    position DOUBLE NOT NULL,
                    createdAt DOUBLE NOT NULL,
                    PRIMARY KEY (sourceID, kind, remoteID)
                );
                CREATE TABLE recent (
                    sourceID TEXT NOT NULL REFERENCES source(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL,
                    remoteID TEXT NOT NULL,
                    titleSnapshot TEXT NOT NULL,
                    playedAt DOUBLE NOT NULL,
                    PRIMARY KEY (sourceID, kind, remoteID)
                );
                CREATE INDEX recent_source_playedAt ON recent(sourceID, playedAt DESC);
                CREATE TABLE sourcePreference (
                    sourceID TEXT NOT NULL REFERENCES source(id) ON DELETE CASCADE,
                    key TEXT NOT NULL,
                    value TEXT NOT NULL,
                    PRIMARY KEY (sourceID, key)
                );
                """)
        }
        migrator.registerMigration("v2-library") { db in
            try db.execute(sql: """
                CREATE TABLE mediaCategory (
                    sourceID TEXT NOT NULL REFERENCES source(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL,
                    remoteID TEXT NOT NULL,
                    name TEXT NOT NULL,
                    position INTEGER NOT NULL,
                    PRIMARY KEY (sourceID, kind, remoteID)
                );
                CREATE TABLE movie (
                    sourceID TEXT NOT NULL REFERENCES source(id) ON DELETE CASCADE,
                    remoteID TEXT NOT NULL,
                    name TEXT NOT NULL,
                    searchName TEXT NOT NULL,
                    posterURL TEXT,
                    rating TEXT,
                    addedAt DOUBLE,
                    containerExtension TEXT,
                    position INTEGER NOT NULL,
                    PRIMARY KEY (sourceID, remoteID)
                );
                CREATE TABLE series (
                    sourceID TEXT NOT NULL REFERENCES source(id) ON DELETE CASCADE,
                    remoteID TEXT NOT NULL,
                    name TEXT NOT NULL,
                    searchName TEXT NOT NULL,
                    posterURL TEXT,
                    plot TEXT,
                    genre TEXT,
                    rating TEXT,
                    releaseDate TEXT,
                    position INTEGER NOT NULL,
                    PRIMARY KEY (sourceID, remoteID)
                );
                CREATE TABLE mediaMembership (
                    sourceID TEXT NOT NULL REFERENCES source(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL,
                    categoryRemoteID TEXT NOT NULL,
                    itemRemoteID TEXT NOT NULL,
                    position INTEGER NOT NULL,
                    PRIMARY KEY (sourceID, kind, categoryRemoteID, itemRemoteID)
                );
                CREATE INDEX mediaMembership_item ON mediaMembership(sourceID, kind, itemRemoteID);
                CREATE VIRTUAL TABLE mediaSearch USING fts5(
                    searchName, sourceID UNINDEXED, kind UNINDEXED, remoteID UNINDEXED, tokenize = 'unicode61'
                );
                CREATE TABLE libraryState (
                    sourceID TEXT PRIMARY KEY NOT NULL REFERENCES source(id) ON DELETE CASCADE,
                    lastSuccessAt DOUBLE,
                    lastAttemptAt DOUBLE,
                    lastErrorCode TEXT,
                    movieCategoryCount INTEGER NOT NULL DEFAULT 0,
                    seriesCategoryCount INTEGER NOT NULL DEFAULT 0,
                    movieCount INTEGER NOT NULL DEFAULT 0,
                    seriesCount INTEGER NOT NULL DEFAULT 0,
                    droppedCount INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE playbackProgress (
                    sourceID TEXT NOT NULL REFERENCES source(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL,
                    remoteID TEXT NOT NULL,
                    title TEXT NOT NULL,
                    seriesRemoteID TEXT,
                    seriesTitle TEXT,
                    seasonNumber INTEGER,
                    episodeNumber INTEGER,
                    containerExtension TEXT,
                    posterURL TEXT,
                    positionSeconds DOUBLE NOT NULL,
                    durationSeconds DOUBLE,
                    completed BOOLEAN NOT NULL DEFAULT 0,
                    updatedAt DOUBLE NOT NULL,
                    PRIMARY KEY (sourceID, kind, remoteID)
                );
                CREATE INDEX playbackProgress_recent ON playbackProgress(sourceID, completed, updatedAt DESC);
                CREATE INDEX playbackProgress_series ON playbackProgress(sourceID, seriesRemoteID);
                """)
        }
        // Personal organization. Keyed by source + provider ID, never by row: catalogue refreshes
        // delete and re-insert channels, and these rows must survive them.
        migrator.registerMigration("v3-organization") { db in
            try db.execute(sql: """
                CREATE TABLE channelOverride (
                    sourceID TEXT NOT NULL REFERENCES source(id) ON DELETE CASCADE,
                    remoteID TEXT NOT NULL,
                    alias TEXT,
                    hidden BOOLEAN NOT NULL DEFAULT 0,
                    PRIMARY KEY (sourceID, remoteID)
                );
                CREATE VIRTUAL TABLE channelAliasSearch USING fts5(
                    searchName, sourceID UNINDEXED, remoteID UNINDEXED, tokenize = 'unicode61'
                );
                CREATE TABLE channelOrder (
                    sourceID TEXT NOT NULL REFERENCES source(id) ON DELETE CASCADE,
                    categoryRemoteID TEXT NOT NULL,
                    channelRemoteID TEXT NOT NULL,
                    position INTEGER NOT NULL,
                    PRIMARY KEY (sourceID, categoryRemoteID, channelRemoteID)
                );
                CREATE TABLE categoryOverride (
                    sourceID TEXT NOT NULL REFERENCES source(id) ON DELETE CASCADE,
                    remoteID TEXT NOT NULL,
                    hidden BOOLEAN NOT NULL DEFAULT 0,
                    position INTEGER,
                    PRIMARY KEY (sourceID, remoteID)
                );
                CREATE TABLE userCollection (
                    id TEXT PRIMARY KEY NOT NULL,
                    sourceID TEXT NOT NULL REFERENCES source(id) ON DELETE CASCADE,
                    name TEXT NOT NULL,
                    position DOUBLE NOT NULL,
                    createdAt DOUBLE NOT NULL
                );
                CREATE INDEX userCollection_source ON userCollection(sourceID, position);
                CREATE TABLE collectionItem (
                    collectionID TEXT NOT NULL REFERENCES userCollection(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL,
                    remoteID TEXT NOT NULL,
                    titleSnapshot TEXT NOT NULL,
                    position DOUBLE NOT NULL,
                    addedAt DOUBLE NOT NULL,
                    PRIMARY KEY (collectionID, kind, remoteID)
                );
                """)
        }
        // Parental locks: categories (live/movie/series) and single items, by provider ID.
        migrator.registerMigration("v4-parental") { db in
            try db.execute(sql: """
                CREATE TABLE lockedContent (
                    sourceID TEXT NOT NULL REFERENCES source(id) ON DELETE CASCADE,
                    scope TEXT NOT NULL,
                    remoteID TEXT NOT NULL,
                    PRIMARY KEY (sourceID, scope, remoteID)
                );
                """)
        }
        return migrator
    }

    /// FTS5 rows are not covered by foreign keys; every source deletion goes through here.
    /// Refreshes delete only their own index (live vs. library).
    static func deleteSearchRows(_ db: Database, sourceID: String) throws {
        try db.execute(sql: "DELETE FROM liveChannelSearch WHERE sourceID = ?", arguments: [sourceID])
        try db.execute(sql: "DELETE FROM mediaSearch WHERE sourceID = ?", arguments: [sourceID])
        try db.execute(sql: "DELETE FROM channelAliasSearch WHERE sourceID = ?", arguments: [sourceID])
    }
}
