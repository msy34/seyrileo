import Foundation
import Testing
@testable import SeyrileoKit

final class TestClock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
}

@MainActor
@Suite struct ParentalGateTests {
    let store = InMemoryPINStore()
    let clock = TestClock()

    func gate() -> ParentalGate {
        let clock = clock
        return ParentalGate(store: store, now: { clock.date })
    }

    @Test func pinIsHashedWithSaltAndValidated() throws {
        let one = PINRecord.make(pin: "1234", iterations: 1000)
        let two = PINRecord.make(pin: "1234", iterations: 1000)
        #expect(one.matches("1234"))
        #expect(!one.matches("1235"))
        #expect(one.salt != two.salt && one.hash != two.hash)
        #expect(!one.hash.contains(Data("1234".utf8)))
        #expect(PINRecord.isValid("0000") && PINRecord.isValid("123456"))
        #expect(!PINRecord.isValid("123") && !PINRecord.isValid("1234567") && !PINRecord.isValid("12a4") && !PINRecord.isValid("١٢٣٤"))
    }

    @Test func noPINMeansNoRestriction() {
        let gate = gate()
        #expect(!gate.isEnabled)
        #expect(gate.allowsRestrictedContent)
    }

    @Test func setUnlockLockAndChange() throws {
        let gate = gate()
        try gate.setPIN("2468", current: nil)
        #expect(gate.isEnabled && gate.isUnlocked)
        gate.lock()
        #expect(!gate.allowsRestrictedContent)
        #expect(gate.verify("2468") == .unlocked)
        // Changing needs the current PIN.
        #expect(throws: ParentalGate.ChangeError.wrongCurrentPIN) { try gate.setPIN("1357", current: "0000") }
        #expect(throws: ParentalGate.ChangeError.invalidPIN) { try gate.setPIN("13", current: "2468") }
        try gate.setPIN("1357", current: "2468")
        gate.lock()
        #expect(gate.verify("2468") != .unlocked)
        #expect(gate.verify("1357") == .unlocked)
        // A new process sees the same PIN, locked.
        let again = self.gate()
        #expect(again.isEnabled && !again.isUnlocked)
    }

    @Test func wrongAttemptsLockOutAndSurviveRestart() throws {
        let gate = gate()
        try gate.setPIN("2468", current: nil)
        gate.lock()
        for remaining in (1...4).reversed() {
            #expect(gate.verify("0000") == .wrong(remainingBeforeLockout: remaining))
        }
        guard case .lockedOut(let until) = gate.verify("0000") else { Issue.record("expected lockout"); return }
        #expect(until == clock.date.addingTimeInterval(30))
        // Even the right PIN is refused during the lockout, also after a restart.
        #expect(gate.verify("2468") == .lockedOut(until: until))
        #expect(self.gate().verify("2468") == .lockedOut(until: until))
        clock.advance(31)
        #expect(gate.verify("0000") == .lockedOut(until: clock.date.addingTimeInterval(60)))
        clock.advance(61)
        #expect(gate.verify("2468") == .unlocked)
        #expect(try store.loadAttempts() == PINAttemptState())
    }

    @Test func lockoutGrowsAndIsCapped() {
        #expect(ParentalGate.lockout(afterFailures: 4) == nil)
        #expect(ParentalGate.lockout(afterFailures: 5) == 30)
        #expect(ParentalGate.lockout(afterFailures: 7) == 120)
        #expect(ParentalGate.lockout(afterFailures: 50) == 900)
    }

    @Test func removeNeedsPINOrDeviceAuthentication() throws {
        let gate = gate()
        try gate.setPIN("2468", current: nil)
        #expect(throws: ParentalGate.ChangeError.wrongCurrentPIN) { try gate.removePIN(current: "1111") }
        try gate.removePIN(current: nil, authorized: true)
        #expect(!gate.isEnabled && gate.allowsRestrictedContent)
        #expect(try store.loadRecord() == nil)
    }
}

@Suite struct ParentalStoreTests {
    @Test func locksByCategoryOrItemAndCascadeWithSource() async throws {
        let bed = try TestBed()
        let source = try bed.addSource()
        let store = ParentalStore(database: bed.database)
        try await store.setLocked(true, scope: .liveCategory, remoteID: "2", sourceID: source.id)
        try await store.setLocked(true, scope: .movie, remoteID: "301", sourceID: source.id)
        try await store.setLocked(true, scope: .series, remoteID: "401", sourceID: source.id)
        let set = try await store.lockSet(sourceID: source.id)

        let live = { MediaKey(providerID: source.id, kind: .live, remoteID: $0) }
        #expect(set.isLocked(live("20"), categoryIDs: ["2"]))
        #expect(set.isLocked(live("21"), categoryIDs: ["1", "2"]))  // any locked category
        #expect(!set.isLocked(live("10"), categoryIDs: ["1"]))
        #expect(set.isLocked(MediaKey(providerID: source.id, kind: .movie, remoteID: "301"), categoryIDs: []))
        // A live category "2" does not lock a movie category "2".
        #expect(!set.isLocked(MediaKey(providerID: source.id, kind: .movie, remoteID: "9"), categoryIDs: ["2"]))
        let series = MediaKey(providerID: source.id, kind: .series, remoteID: "401")
        #expect(set.isLocked(MediaKey(providerID: source.id, kind: .episode, remoteID: "501"), categoryIDs: [], seriesKey: series))

        try await store.setLocked(false, scope: .liveCategory, remoteID: "2", sourceID: source.id)
        #expect(!(try await store.lockSet(sourceID: source.id)).isCategoryLocked(.live, "2"))

        try bed.sources.saveSources([])
        #expect(try await bed.database.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM lockedContent") } == 0)
    }
}
