import Foundation
import GRDB

/// Saved position for a movie or episode. Live channels never get progress.
public struct PlaybackProgress: Identifiable, Hashable, Sendable {
    public let key: MediaKey
    public let title: String
    public let seriesKey: MediaKey?
    public let seriesTitle: String?
    public let seasonNumber: Int?
    public let episodeNumber: Int?
    public let containerExtension: String?
    public let posterURL: URL?
    public let position: TimeInterval
    public let duration: TimeInterval?
    public let completed: Bool
    public let updatedAt: Date

    public var id: MediaKey { key }

    public init(
        key: MediaKey, title: String, seriesKey: MediaKey? = nil, seriesTitle: String? = nil, seasonNumber: Int? = nil,
        episodeNumber: Int? = nil, containerExtension: String? = nil, posterURL: URL? = nil, position: TimeInterval,
        duration: TimeInterval?, completed: Bool = false, updatedAt: Date = Date()
    ) {
        self.key = key
        self.title = title
        self.seriesKey = seriesKey
        self.seriesTitle = seriesTitle
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.containerExtension = containerExtension
        self.posterURL = posterURL
        self.position = position
        self.duration = duration
        self.completed = completed
        self.updatedAt = updatedAt
    }

    /// 0...1 when the duration is known.
    public var fraction: Double? {
        guard let duration, duration > 0 else { return nil }
        return min(max(position / duration, 0), 1)
    }

    /// Worth offering "Resume": started for real and not finished.
    public var isResumable: Bool { !completed && position >= ProgressPolicy.minimumResumePosition }
}

public enum ProgressPolicy {
    /// Positions before this are treated as "not really started".
    public static let minimumResumePosition: TimeInterval = 30
    /// Seconds from the end that count as watched (credits).
    public static let completionTail: TimeInterval = 90
    public static let completionFraction = 0.95

    public static func isCompleted(position: TimeInterval, duration: TimeInterval?) -> Bool {
        guard let duration, duration.isFinite, duration > 0 else { return false }
        return position >= duration * completionFraction || duration - position <= completionTail
    }

    /// Where to start: the saved position, or 0 when nothing is resumable.
    public static func startPosition(for progress: PlaybackProgress?) -> TimeInterval {
        guard let progress, progress.isResumable else { return 0 }
        return progress.position
    }
}

public struct ProgressStore: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Upserts progress. Ignores live items, non-finite values and unknown sources.
    public func save(_ progress: PlaybackProgress) async throws {
        guard progress.key.kind == .movie || progress.key.kind == .episode, progress.position.isFinite,
              progress.position >= 0
        else { return }
        let duration = progress.duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let completed = progress.completed || ProgressPolicy.isCompleted(position: progress.position, duration: duration)
        try await database.writer.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM source WHERE id = ?)", arguments: [progress.key.providerID.uuidString]) == true
            else { return }
            try db.execute(
                sql: """
                    INSERT INTO playbackProgress (sourceID, kind, remoteID, title, seriesRemoteID, seriesTitle, seasonNumber,
                        episodeNumber, containerExtension, posterURL, positionSeconds, durationSeconds, completed, updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(sourceID, kind, remoteID) DO UPDATE SET title = excluded.title,
                        seriesRemoteID = excluded.seriesRemoteID, seriesTitle = excluded.seriesTitle,
                        seasonNumber = excluded.seasonNumber, episodeNumber = excluded.episodeNumber,
                        containerExtension = excluded.containerExtension, posterURL = excluded.posterURL,
                        positionSeconds = excluded.positionSeconds,
                        durationSeconds = COALESCE(excluded.durationSeconds, durationSeconds),
                        completed = excluded.completed, updatedAt = excluded.updatedAt
                    """,
                arguments: [
                    progress.key.providerID.uuidString, progress.key.kind.rawValue, progress.key.remoteID, progress.title,
                    progress.seriesKey?.remoteID, progress.seriesTitle, progress.seasonNumber, progress.episodeNumber,
                    progress.containerExtension, progress.posterURL?.absoluteString, progress.position, duration, completed,
                    progress.updatedAt.timeIntervalSince1970,
                ])
        }
    }

    public func progress(_ key: MediaKey) async throws -> PlaybackProgress? {
        try await database.writer.read { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM playbackProgress WHERE sourceID = ? AND kind = ? AND remoteID = ?",
                arguments: [key.providerID.uuidString, key.kind.rawValue, key.remoteID]
            ).flatMap { Self.progress($0, sourceID: key.providerID) }
        }
    }

    /// Progress for all episodes of one series, keyed by episode key.
    public func episodeProgress(seriesKey: MediaKey) async throws -> [MediaKey: PlaybackProgress] {
        try await database.writer.read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT * FROM playbackProgress WHERE sourceID = ? AND kind = 'episode' AND seriesRemoteID = ?",
                arguments: [seriesKey.providerID.uuidString, seriesKey.remoteID])
            return Dictionary(rows.compactMap { Self.progress($0, sourceID: seriesKey.providerID) }.map { ($0.key, $0) },
                              uniquingKeysWith: { a, _ in a })
        }
    }

    /// Unfinished movies and episodes, newest first. One entry per series (its latest episode).
    public func continueWatching(sourceID: UUID, limit: Int = 20) async throws -> [PlaybackProgress] {
        try await database.writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM playbackProgress WHERE sourceID = ? AND completed = 0 AND positionSeconds >= ?
                    ORDER BY updatedAt DESC
                    """,
                arguments: [sourceID.uuidString, ProgressPolicy.minimumResumePosition])
            var seenSeries = Set<String>()
            var result: [PlaybackProgress] = []
            for row in rows {
                guard let progress = Self.progress(row, sourceID: sourceID) else { continue }
                if let series = progress.seriesKey?.remoteID {
                    guard seenSeries.insert(series).inserted else { continue }
                }
                result.append(progress)
                if result.count == limit { break }
            }
            return result
        }
    }

    public func remove(_ key: MediaKey) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "DELETE FROM playbackProgress WHERE sourceID = ? AND kind = ? AND remoteID = ?",
                arguments: [key.providerID.uuidString, key.kind.rawValue, key.remoteID])
        }
    }

    static func progress(_ row: Row, sourceID: UUID) -> PlaybackProgress? {
        guard let kind = MediaKind(rawValue: row["kind"]) else { return nil }
        let seriesID: String? = row["seriesRemoteID"]
        let poster: String? = row["posterURL"]
        return PlaybackProgress(
            key: MediaKey(providerID: sourceID, kind: kind, remoteID: row["remoteID"]),
            title: row["title"],
            seriesKey: seriesID.map { MediaKey(providerID: sourceID, kind: .series, remoteID: $0) },
            seriesTitle: row["seriesTitle"], seasonNumber: row["seasonNumber"], episodeNumber: row["episodeNumber"],
            containerExtension: row["containerExtension"], posterURL: poster.flatMap(URL.init(string:)),
            position: row["positionSeconds"], duration: row["durationSeconds"], completed: row["completed"],
            updatedAt: Date(timeIntervalSince1970: row["updatedAt"]))
    }
}
