import Foundation
import GRDB

/// Everything a movies + series refresh downloads before anything is written locally.
public struct LibrarySnapshot: Sendable {
    public let movieCategories: CatalogPage<MediaCategory>
    public let movies: CatalogPage<Movie>
    public let seriesCategories: CatalogPage<MediaCategory>
    public let series: CatalogPage<Series>

    public init(
        movieCategories: CatalogPage<MediaCategory>, movies: CatalogPage<Movie>,
        seriesCategories: CatalogPage<MediaCategory>, series: CatalogPage<Series>
    ) {
        self.movieCategories = movieCategories
        self.movies = movies
        self.seriesCategories = seriesCategories
        self.series = series
    }
}

extension XtreamClient {
    /// Four requests in sequence (VOD categories, all VOD, series categories, all series).
    public func fetchLibrarySnapshot() async throws -> LibrarySnapshot {
        let movieCategories = try await vodCategories()
        try Task.checkCancellation()
        let movies = try await vodStreams()
        try Task.checkCancellation()
        let seriesCategories = try await seriesCategories()
        try Task.checkCancellation()
        let series = try await seriesList()
        return LibrarySnapshot(movieCategories: movieCategories, movies: movies, seriesCategories: seriesCategories, series: series)
    }
}

public struct LibraryStatus: Equatable, Sendable {
    public let lastSuccessAt: Date?
    public let lastAttemptAt: Date?
    public let lastErrorCode: String?
    public let movieCategoryCount: Int
    public let seriesCategoryCount: Int
    public let movieCount: Int
    public let seriesCount: Int
    public let droppedCount: Int

    public var hasCatalog: Bool { lastSuccessAt != nil }
}

public struct MediaCategorySummary: Identifiable, Hashable, Sendable {
    public let category: MediaCategory
    public let itemCount: Int
    public var id: String { category.remoteID }
}

public enum LibraryItem: Identifiable, Hashable, Sendable {
    case movie(Movie)
    case series(Series)

    public var id: MediaKey { key }
    public var key: MediaKey {
        switch self {
        case .movie(let movie): movie.key
        case .series(let series): series.key
        }
    }
    public var name: String {
        switch self {
        case .movie(let movie): movie.name
        case .series(let series): series.name
        }
    }
    public var categoryIDs: [String] {
        switch self {
        case .movie(let movie): movie.categoryIDs
        case .series(let series): series.categoryIDs
        }
    }
        public var posterURL: URL? {
        switch self {
        case .movie(let movie): movie.posterURL
        case .series(let series): series.posterURL
        }
    }
}

/// Movies and series catalogue. Same guarantees as `CatalogStore`: download first, then one
/// write transaction per source; failures and cancellation leave the saved library untouched;
/// progress and favorites live in other tables.
public struct LibraryCatalogStore: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    @discardableResult
    public func refresh(
        sourceID: UUID, now: @Sendable () -> Date = Date.init,
        fetch: @Sendable () async throws -> LibrarySnapshot
    ) async throws -> CatalogStore.RefreshOutcome {
        let snapshot: LibrarySnapshot
        do {
            snapshot = try await fetch()
            try Task.checkCancellation()
        } catch is CancellationError {
            return .cancelled
        } catch XtreamError.cancelled {
            return .cancelled
        } catch {
            try? await recordFailure(sourceID: sourceID, code: CatalogStore.errorCode(error), at: now())
            throw error
        }
        try await apply(snapshot, sourceID: sourceID, at: now())
        return .applied(
            categories: snapshot.movieCategories.items.count + snapshot.seriesCategories.items.count,
            channels: snapshot.movies.items.count + snapshot.series.items.count)
    }

    func apply(_ snapshot: LibrarySnapshot, sourceID: UUID, at date: Date) async throws {
        let sid = sourceID.uuidString
        try await database.writer.write { db in
            for table in ["mediaSearch", "mediaMembership", "movie", "series", "mediaCategory"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE sourceID = ?", arguments: [sid])
            }
            let insertCategory = try db.cachedStatement(
                sql: "INSERT OR IGNORE INTO mediaCategory (sourceID, kind, remoteID, name, position) VALUES (?, ?, ?, ?, ?)")
            for (kind, page) in [(MediaKind.movie, snapshot.movieCategories), (.series, snapshot.seriesCategories)] {
                for (index, category) in page.items.enumerated() {
                    try insertCategory.execute(arguments: [sid, kind.rawValue, category.remoteID, category.name, index])
                }
            }
            let insertSearch = try db.cachedStatement(
                sql: "INSERT INTO mediaSearch (searchName, sourceID, kind, remoteID) VALUES (?, ?, ?, ?)")
            let insertMembership = try db.cachedStatement(sql: """
                INSERT OR IGNORE INTO mediaMembership (sourceID, kind, categoryRemoteID, itemRemoteID, position)
                VALUES (?, ?, ?, ?, ?)
                """)

            let insertMovie = try db.cachedStatement(sql: """
                INSERT OR IGNORE INTO movie (sourceID, remoteID, name, searchName, posterURL, rating, addedAt, containerExtension, position)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            var movieIDs = Set<String>()
            for (index, movie) in snapshot.movies.items.enumerated() {
                let id = movie.key.remoteID
                guard movieIDs.insert(id).inserted else { continue }
                let searchName = SearchText.normalize(movie.name)
                try insertMovie.execute(arguments: [
                    sid, id, movie.name, searchName, movie.posterURL?.absoluteString, movie.rating,
                    movie.addedAt?.timeIntervalSince1970, movie.containerExtension, index,
                ])
                try insertSearch.execute(arguments: [searchName, sid, MediaKind.movie.rawValue, id])
                for categoryID in movie.categoryIDs {
                    try insertMembership.execute(arguments: [sid, MediaKind.movie.rawValue, categoryID, id, index])
                }
            }

            let insertSeries = try db.cachedStatement(sql: """
                INSERT OR IGNORE INTO series (sourceID, remoteID, name, searchName, posterURL, plot, genre, rating, releaseDate, position)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            var seriesIDs = Set<String>()
            for (index, series) in snapshot.series.items.enumerated() {
                let id = series.key.remoteID
                guard seriesIDs.insert(id).inserted else { continue }
                let searchName = SearchText.normalize(series.name)
                try insertSeries.execute(arguments: [
                    sid, id, series.name, searchName, series.posterURL?.absoluteString, series.plot, series.genre,
                    series.rating, series.releaseDate, index,
                ])
                try insertSearch.execute(arguments: [searchName, sid, MediaKind.series.rawValue, id])
                for categoryID in series.categoryIDs {
                    try insertMembership.execute(arguments: [sid, MediaKind.series.rawValue, categoryID, id, index])
                }
            }

            let dropped = snapshot.movieCategories.droppedCount + snapshot.movies.droppedCount
                + snapshot.seriesCategories.droppedCount + snapshot.series.droppedCount
            try db.execute(
                sql: """
                    INSERT INTO libraryState (sourceID, lastSuccessAt, lastAttemptAt, lastErrorCode, movieCategoryCount,
                        seriesCategoryCount, movieCount, seriesCount, droppedCount)
                    VALUES (?, ?, ?, NULL, ?, ?, ?, ?, ?)
                    ON CONFLICT(sourceID) DO UPDATE SET lastSuccessAt = excluded.lastSuccessAt,
                        lastAttemptAt = excluded.lastAttemptAt, lastErrorCode = NULL,
                        movieCategoryCount = excluded.movieCategoryCount, seriesCategoryCount = excluded.seriesCategoryCount,
                        movieCount = excluded.movieCount, seriesCount = excluded.seriesCount, droppedCount = excluded.droppedCount
                    """,
                arguments: [
                    sid, date.timeIntervalSince1970, date.timeIntervalSince1970, snapshot.movieCategories.items.count,
                    snapshot.seriesCategories.items.count, movieIDs.count, seriesIDs.count, dropped,
                ])
        }
    }

    private func recordFailure(sourceID: UUID, code: String, at date: Date) async throws {
        try await database.writer.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM source WHERE id = ?)", arguments: [sourceID.uuidString]) == true
            else { return }
            try db.execute(
                sql: """
                    INSERT INTO libraryState (sourceID, lastAttemptAt, lastErrorCode) VALUES (?, ?, ?)
                    ON CONFLICT(sourceID) DO UPDATE SET lastAttemptAt = excluded.lastAttemptAt, lastErrorCode = excluded.lastErrorCode
                    """,
                arguments: [sourceID.uuidString, date.timeIntervalSince1970, code])
        }
    }

    // MARK: - Queries

    public func status(sourceID: UUID) async throws -> LibraryStatus? {
        try await database.writer.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM libraryState WHERE sourceID = ?", arguments: [sourceID.uuidString])
            else { return nil }
            let success: Double? = row["lastSuccessAt"]
            let attempt: Double? = row["lastAttemptAt"]
            return LibraryStatus(
                lastSuccessAt: success.map(Date.init(timeIntervalSince1970:)),
                lastAttemptAt: attempt.map(Date.init(timeIntervalSince1970:)),
                lastErrorCode: row["lastErrorCode"], movieCategoryCount: row["movieCategoryCount"],
                seriesCategoryCount: row["seriesCategoryCount"], movieCount: row["movieCount"],
                seriesCount: row["seriesCount"], droppedCount: row["droppedCount"])
        }
    }

    public func categories(sourceID: UUID, kind: MediaKind) async throws -> [MediaCategorySummary] {
        try await database.writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT c.remoteID, c.name,
                        (SELECT COUNT(*) FROM mediaMembership m WHERE m.sourceID = c.sourceID AND m.kind = c.kind
                            AND m.categoryRemoteID = c.remoteID) AS itemCount
                    FROM mediaCategory c WHERE c.sourceID = ? AND c.kind = ? ORDER BY c.position
                    """,
                arguments: [sourceID.uuidString, kind.rawValue]
            ).map {
                MediaCategorySummary(
                    category: MediaCategory(providerID: sourceID, kind: kind, remoteID: $0["remoteID"], name: $0["name"]),
                    itemCount: $0["itemCount"])
            }
        }
    }

    public func items(sourceID: UUID, kind: MediaKind, categoryID: String) async throws -> [LibraryItem] {
        let table = kind == .series ? "series" : "movie"
        return try await database.writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT t.* FROM mediaMembership m
                    JOIN \(table) t ON t.sourceID = m.sourceID AND t.remoteID = m.itemRemoteID
                    WHERE m.sourceID = ? AND m.kind = ? AND m.categoryRemoteID = ? ORDER BY m.position
                    """,
                arguments: [sourceID.uuidString, kind.rawValue, categoryID]
            ).map { Self.item($0, kind: kind, sourceID: sourceID, db: db) }
        }
    }

    public func movie(_ key: MediaKey) async throws -> Movie? {
        guard key.kind == .movie else { return nil }
        return try await database.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM movie WHERE sourceID = ? AND remoteID = ?", arguments: [key.providerID.uuidString, key.remoteID])
                .flatMap { row -> Movie? in
                    if case .movie(let movie) = Self.item(row, kind: .movie, sourceID: key.providerID, db: db) { return movie }
                    return nil
                }
        }
    }

    public func series(_ key: MediaKey) async throws -> Series? {
        guard key.kind == .series else { return nil }
        return try await database.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM series WHERE sourceID = ? AND remoteID = ?", arguments: [key.providerID.uuidString, key.remoteID])
                .flatMap { row -> Series? in
                    if case .series(let series) = Self.item(row, kind: .series, sourceID: key.providerID, db: db) { return series }
                    return nil
                }
        }
    }

    /// Indexed word-prefix search (Turkish-aware, see `SearchText`) within movies or series.
    public func search(
        sourceID: UUID, kind: MediaKind, query: String, categoryID: String? = nil, limit: Int = 200
    ) async throws -> (items: [LibraryItem], isTruncated: Bool) {
        guard let match = SearchText.ftsPrefixQuery(query) else { return ([], false) }
        let table = kind == .series ? "series" : "movie"
        return try await database.writer.read { db in
            var sql = """
                SELECT t.* FROM mediaSearch s
                JOIN \(table) t ON t.sourceID = s.sourceID AND t.remoteID = s.remoteID
                WHERE mediaSearch MATCH ? AND s.sourceID = ? AND s.kind = ?
                """
            var arguments: StatementArguments = [match, sourceID.uuidString, kind.rawValue]
            if let categoryID {
                sql += """
                     AND EXISTS (SELECT 1 FROM mediaMembership m WHERE m.sourceID = t.sourceID AND m.kind = ?
                        AND m.itemRemoteID = t.remoteID AND m.categoryRemoteID = ?)
                    """
                arguments += [kind.rawValue, categoryID]
            }
            sql += " ORDER BY t.position LIMIT ?"
            arguments += [limit + 1]
            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            return (rows.prefix(limit).map { Self.item($0, kind: kind, sourceID: sourceID, db: db) }, rows.count > limit)
        }
    }

    static func item(_ row: Row, kind: MediaKind, sourceID: UUID, db: Database) -> LibraryItem {
        let remoteID: String = row["remoteID"]
        let categoryIDs = (try? String.fetchAll(
            db, sql: "SELECT categoryRemoteID FROM mediaMembership WHERE sourceID = ? AND kind = ? AND itemRemoteID = ?",
            arguments: [sourceID.uuidString, kind.rawValue, remoteID])) ?? []
        let poster: String? = row["posterURL"]
        if kind == .series {
            return .series(Series(
                key: MediaKey(providerID: sourceID, kind: .series, remoteID: remoteID), name: row["name"],
                posterURL: poster.flatMap(URL.init(string:)), plot: row["plot"], genre: row["genre"],
                rating: row["rating"], releaseDate: row["releaseDate"], categoryIDs: categoryIDs))
        }
        let added: Double? = row["addedAt"]
        return .movie(Movie(
            key: MediaKey(providerID: sourceID, kind: .movie, remoteID: remoteID), name: row["name"],
            posterURL: poster.flatMap(URL.init(string:)), rating: row["rating"],
            addedAt: added.map(Date.init(timeIntervalSince1970:)), categoryIDs: categoryIDs,
            containerExtension: row["containerExtension"]))
    }
}
