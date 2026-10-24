import Foundation
import GRDB

/// A reminder for one programme on one channel. The notification fires `lead` before `start`.
public struct ProgramReminder: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let channel: MediaKey
    public let channelTitle: String
    public let programTitle: String
    public let start: Date
    public let end: Date
    public let lead: TimeInterval

    public init(
        id: UUID = UUID(), channel: MediaKey, channelTitle: String, programTitle: String, start: Date, end: Date,
        lead: TimeInterval = ProgramReminder.defaultLead
    ) {
        self.id = id
        self.channel = channel
        self.channelTitle = channelTitle
        self.programTitle = programTitle
        self.start = start
        self.end = end
        self.lead = lead
    }

    public static let defaultLead: TimeInterval = 5 * 60

    /// When the notification should fire: `lead` before the start, but never in the past
    /// (a programme starting in 2 minutes notifies in a few seconds).
    public func fireDate(now: Date) -> Date {
        max(start.addingTimeInterval(-lead), now.addingTimeInterval(5))
    }

    /// Notification identifier; stable for the row.
    public var notificationID: String { "reminder.\(id.uuidString)" }
}

public enum ReminderError: Error, Equatable, Sendable {
    /// The programme has already started or ended.
    case alreadyStarted
    /// iOS keeps at most 64 pending notifications per app; Seyrileo stops at `ReminderStore.limit`.
    case tooMany(limit: Int)
}

public struct ReminderStore: Sendable {
    /// Below iOS's 64 pending-notification limit, leaving room for the app's other uses.
    public static let limit = 60
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    @discardableResult
    public func add(_ reminder: ProgramReminder, now: Date = Date()) async throws -> ProgramReminder {
        guard reminder.start > now else { throw ReminderError.alreadyStarted }
        return try await database.writer.write { db in
            let sid = reminder.channel.providerID.uuidString
            // The same programme twice is one reminder.
            if let existing = try Row.fetchOne(
                db, sql: "SELECT * FROM reminder WHERE sourceID = ? AND channelRemoteID = ? AND start = ?",
                arguments: [sid, reminder.channel.remoteID, reminder.start.timeIntervalSince1970]
            ).flatMap(Self.reminder) {
                return existing
            }
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM reminder WHERE end > ?", arguments: [now.timeIntervalSince1970]) ?? 0
            guard count < Self.limit else { throw ReminderError.tooMany(limit: Self.limit) }
            try db.execute(
                sql: """
                    INSERT INTO reminder (id, sourceID, channelRemoteID, channelTitle, programTitle, start, end, leadSeconds, createdAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    reminder.id.uuidString, sid, reminder.channel.remoteID, reminder.channelTitle, reminder.programTitle,
                    reminder.start.timeIntervalSince1970, reminder.end.timeIntervalSince1970, reminder.lead,
                    now.timeIntervalSince1970,
                ])
            return reminder
        }
    }

    public func remove(_ id: UUID) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM reminder WHERE id = ?", arguments: [id.uuidString])
        }
    }

    /// Reminders whose programme has not ended, soonest first (all sources).
    public func upcoming(now: Date = Date()) async throws -> [ProgramReminder] {
        try await database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM reminder WHERE end > ? ORDER BY start", arguments: [now.timeIntervalSince1970])
                .compactMap(Self.reminder)
        }
    }

    public func reminder(for channel: MediaKey, start: Date) async throws -> ProgramReminder? {
        try await database.writer.read { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM reminder WHERE sourceID = ? AND channelRemoteID = ? AND start = ?",
                arguments: [channel.providerID.uuidString, channel.remoteID, start.timeIntervalSince1970]
            ).flatMap(Self.reminder)
        }
    }

    /// Deletes reminders whose programme has ended. Returns how many were removed.
    @discardableResult
    public func pruneEnded(now: Date = Date()) async throws -> Int {
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM reminder WHERE end <= ?", arguments: [now.timeIntervalSince1970])
            return db.changesCount
        }
    }

    static func reminder(_ row: Row) -> ProgramReminder? {
        guard let id = UUID(uuidString: row["id"]), let source = UUID(uuidString: row["sourceID"]) else { return nil }
        return ProgramReminder(
            id: id, channel: MediaKey(providerID: source, kind: .live, remoteID: row["channelRemoteID"]),
            channelTitle: row["channelTitle"], programTitle: row["programTitle"],
            start: Date(timeIntervalSince1970: row["start"]), end: Date(timeIntervalSince1970: row["end"]),
            lead: row["leadSeconds"])
    }
}
