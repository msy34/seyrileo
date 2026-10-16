import Foundation
import Observation

/// Parental PIN state for the whole app: whether a PIN is set, whether this session is
/// unlocked, and brute-force protection (5 free attempts, then a growing lockout).
///
/// The session locks again when the app goes to the background (`lock()`), so a device handed
/// over later starts locked.
@MainActor
@Observable
public final class ParentalGate {
    public enum Verification: Equatable, Sendable {
        case unlocked
        case wrong(remainingBeforeLockout: Int)
        case lockedOut(until: Date)
    }

    public enum ChangeError: Error, Equatable, Sendable {
        case invalidPIN
        case wrongCurrentPIN
        case lockedOut(until: Date)
    }

    public static let freeAttempts = 5

    public private(set) var isEnabled = false
    public private(set) var isUnlocked = false
    public private(set) var lockedUntil: Date?

    @ObservationIgnored private let store: PINStore
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var record: PINRecord?
    @ObservationIgnored private var attempts = PINAttemptState()

    public init(store: PINStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.now = now
        record = try? store.loadRecord()
        attempts = (try? store.loadAttempts()) ?? PINAttemptState()
        isEnabled = record != nil
        lockedUntil = attempts.lockedUntil
    }

    /// No PIN means nothing is restricted.
    public var allowsRestrictedContent: Bool { !isEnabled || isUnlocked }

    /// Lockout after the free attempts: 30 s, doubling per further failure, at most 15 min.
    static func lockout(afterFailures failures: Int) -> TimeInterval? {
        guard failures >= freeAttempts else { return nil }
        let exponent = min(failures - freeAttempts, 5)
        return min(30 * pow(2, Double(exponent)), 15 * 60)
    }

    public func verify(_ pin: String) -> Verification {
        if let until = attempts.lockedUntil, until > now() { return .lockedOut(until: until) }
        guard let record else {
            isUnlocked = true
            return .unlocked
        }
        if record.matches(pin) {
            attempts = PINAttemptState()
            persistAttempts()
            isUnlocked = true
            return .unlocked
        }
        attempts.failures += 1
        if let duration = Self.lockout(afterFailures: attempts.failures) {
            attempts.lockedUntil = now().addingTimeInterval(duration)
        }
        persistAttempts()
        if let until = attempts.lockedUntil, until > now() { return .lockedOut(until: until) }
        return .wrong(remainingBeforeLockout: max(0, Self.freeAttempts - attempts.failures))
    }

    /// After a successful device-owner authentication (Face ID / Touch ID / passcode).
    public func unlockWithDeviceAuthentication() {
        guard isEnabled else { return }
        attempts = PINAttemptState()
        persistAttempts()
        isUnlocked = true
    }

    public func lock() {
        isUnlocked = false
    }

    /// Sets a new PIN. When one exists, `current` must match it (or the session must be
    /// unlocked by device authentication, passed as `authorized`).
    public func setPIN(_ new: String, current: String?, authorized: Bool = false) throws {
        guard PINRecord.isValid(new) else { throw ChangeError.invalidPIN }
        if record != nil, !authorized {
            switch verify(current ?? "") {
            case .unlocked: break
            case .wrong: throw ChangeError.wrongCurrentPIN
            case .lockedOut(let until): throw ChangeError.lockedOut(until: until)
            }
        }
        let fresh = PINRecord.make(pin: new)
        try store.saveRecord(fresh)
        record = fresh
        isEnabled = true
        isUnlocked = true
    }

    public func removePIN(current: String?, authorized: Bool = false) throws {
        guard record != nil else { return }
        if !authorized {
            switch verify(current ?? "") {
            case .unlocked: break
            case .wrong: throw ChangeError.wrongCurrentPIN
            case .lockedOut(let until): throw ChangeError.lockedOut(until: until)
            }
        }
        try store.saveRecord(nil)
        record = nil
        attempts = PINAttemptState()
        persistAttempts()
        isEnabled = false
        isUnlocked = false
    }

    private func persistAttempts() {
        lockedUntil = attempts.lockedUntil
        try? store.saveAttempts(attempts)
    }
}
