import Foundation
import LocalAuthentication
import Observation
import SeyrileoKit

/// Thrown when the user closes the PIN prompt; callers treat it as "do nothing".
enum ParentalLockError: Error {
    case cancelled
}

/// Parental controls for the running app: the PIN gate, the active source's locked content,
/// and the PIN prompt. Every playback request passes through `AppModel.playbackItem`, which
/// asks `authorize(_:)` first, so lists, search, Your Space, collections, the guide, channel
/// and episode switching in the player (and later reminders) are all covered.
@MainActor
@Observable
final class ParentalModel {
    struct Request: Identifiable {
        let id = UUID()
        let continuation: CheckedContinuation<Bool, Never>
    }

    let gate: ParentalGate
    private(set) var lockSet = LockSet()
    private(set) var request: Request?
    /// Presenters register in order; the topmost one (e.g. the player) shows the prompt.
    private(set) var presenters: [UUID] = []
    /// Incremented when locks change so views can reload.
    private(set) var revision = 0

    var usesBiometrics: Bool {
        didSet { defaults.set(usesBiometrics, forKey: Self.biometricsKey) }
    }

    @ObservationIgnored private var store: ParentalStore?
    @ObservationIgnored private var sourceID: UUID?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private static let biometricsKey = "parentalUsesBiometrics"

    init(gate: ParentalGate, defaults: UserDefaults = .standard) {
        self.gate = gate
        self.defaults = defaults
        usesBiometrics = defaults.object(forKey: Self.biometricsKey) as? Bool ?? true
    }

    // MARK: - Source

    func activate(store: ParentalStore?, sourceID: UUID?) async {
        self.store = store
        self.sourceID = sourceID
        await reload()
    }

    private func reload() async {
        if let store, let sourceID {
            lockSet = (try? await store.lockSet(sourceID: sourceID)) ?? LockSet()
        } else {
            lockSet = LockSet()
        }
        revision += 1
    }

    // MARK: - Questions views ask

    /// Locked content is visible and playable only while unlocked (or without a PIN).
    var isRestricting: Bool { gate.isEnabled && !gate.isUnlocked }

    func isLocked(_ channel: LiveChannel) -> Bool {
        lockSet.isLocked(channel.key, categoryIDs: channel.categoryIDs)
    }

    func isLocked(categoryID: String, kind: MediaKind) -> Bool {
        lockSet.isCategoryLocked(kind, categoryID)
    }

    func isLocked(_ key: MediaKey, categoryIDs: [String], seriesKey: MediaKey? = nil) -> Bool {
        lockSet.isLocked(key, categoryIDs: categoryIDs, seriesKey: seriesKey)
    }

    func isMasked(_ channel: LiveChannel) -> Bool { isRestricting && isLocked(channel) }
    func isMasked(categoryID: String, kind: MediaKind) -> Bool { isRestricting && isLocked(categoryID: categoryID, kind: kind) }
    func isMasked(_ key: MediaKey, categoryIDs: [String], seriesKey: MediaKey? = nil) -> Bool {
        isRestricting && isLocked(key, categoryIDs: categoryIDs, seriesKey: seriesKey)
    }

    // MARK: - Unlocking

    /// true when the content may be shown now; otherwise asks for the PIN (or Face ID).
    func requireUnlock() async -> Bool {
        guard isRestricting else { return true }
        if usesBiometrics, await authenticateWithBiometrics() { return true }
        if let request {
            // One prompt at a time: a second caller is refused.
            _ = request
            return false
        }
        return await withCheckedContinuation { continuation in
            request = Request(continuation: continuation)
        }
    }

    /// Throws `ParentalLockError.cancelled` unless the content may be played.
    func authorize(isLocked: Bool) async throws {
        guard isLocked else { return }
        guard await requireUnlock() else { throw ParentalLockError.cancelled }
    }

    func finishRequest(unlocked: Bool) {
        guard let request else { return }
        self.request = nil
        request.continuation.resume(returning: unlocked)
    }

    var biometryType: LABiometryType {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType
    }

    /// Biometrics only — not the device passcode, which children often know.
    func authenticateWithBiometrics() async -> Bool {
        guard gate.isEnabled else { return true }
        let context = LAContext()
        context.localizedFallbackTitle = String(localized: "Enter PIN")
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return false }
        let reason = String(localized: "Unlock content protected by parental controls.")
        guard (try? await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)) == true
        else { return false }
        gate.unlockWithDeviceAuthentication()
        return true
    }

    func lockNow() {
        gate.lock()
        finishRequest(unlocked: false)
    }

    // MARK: - Presenters

    func register(_ id: UUID) { presenters.append(id) }
    func unregister(_ id: UUID) { presenters.removeAll { $0 == id } }

    // MARK: - Changing locks (always behind the PIN)

    func setLocked(_ locked: Bool, scope: LockScope, remoteID: String) async {
        guard let store, let sourceID, await requireUnlock() else { return }
        try? await store.setLocked(locked, scope: scope, remoteID: remoteID, sourceID: sourceID)
        await reload()
    }
}
