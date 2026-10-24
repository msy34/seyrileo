import Foundation
import GRDB
import Testing
@testable import SeyrileoKit

@Suite struct ReminderTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func reminder(_ source: UUID, channel: String = "10", startIn: TimeInterval, title: String = "Maç") -> ProgramReminder {
        ProgramReminder(
            channel: MediaKey(providerID: source, kind: .live, remoteID: channel), channelTitle: "TRT 1", programTitle: title,
            start: now.addingTimeInterval(startIn), end: now.addingTimeInterval(startIn + 3600))
    }

    @Test func fireDateIsLeadBeforeStartButNeverPast() {
        let source = UUID()
        #expect(reminder(source, startIn: 3600).fireDate(now: now) == now.addingTimeInterval(3600 - 300))
        // Starting in 2 minutes: notify almost immediately rather than never.
        #expect(reminder(source, startIn: 120).fireDate(now: now) == now.addingTimeInterval(5))
    }

    @Test func addListRemoveAndDeduplicate() async throws {
        let bed = try TestBed()
        let source = try bed.addSource()
        let store = ReminderStore(database: bed.database)
        let first = try await store.add(reminder(source.id, startIn: 7200), now: now)
        let again = try await store.add(reminder(source.id, startIn: 7200), now: now)
        #expect(again.id == first.id)
        try await store.add(reminder(source.id, channel: "11", startIn: 3600), now: now)
        #expect(try await store.upcoming(now: now).map(\.channel.remoteID) == ["11", "10"])
        #expect(try await store.reminder(for: first.channel, start: first.start)?.id == first.id)
        try await store.remove(first.id)
        #expect(try await store.upcoming(now: now).count == 1)
    }

    @Test func startedProgrammesAndLimitAreRefused() async throws {
        let bed = try TestBed()
        let source = try bed.addSource()
        let store = ReminderStore(database: bed.database)
        await #expect(throws: ReminderError.alreadyStarted) { try await store.add(reminder(source.id, startIn: -60), now: now) }
        for index in 0..<ReminderStore.limit {
            try await store.add(reminder(source.id, channel: "\(index)", startIn: 3600), now: now)
        }
        await #expect(throws: ReminderError.tooMany(limit: ReminderStore.limit)) {
            try await store.add(reminder(source.id, channel: "x", startIn: 3600), now: now)
        }
    }

    @Test func endedRemindersArePrunedAndSourceRemovalCascades() async throws {
        let bed = try TestBed()
        let source = try bed.addSource()
        let store = ReminderStore(database: bed.database)
        try await store.add(reminder(source.id, startIn: 600), now: now)
        try await store.add(reminder(source.id, channel: "11", startIn: 86_400), now: now)
        #expect(try await store.pruneEnded(now: now.addingTimeInterval(5000)) == 1)
        try bed.sources.saveSources([])
        #expect(try await store.upcoming(now: now).isEmpty)
    }
}
