import CommonCrypto
import Foundation
import Security

/// A salted PBKDF2-SHA256 hash of the parental PIN. The PIN itself is never stored.
public struct PINRecord: Codable, Equatable, Sendable {
    public let salt: Data
    public let hash: Data
    public let iterations: Int

    public static let defaultIterations = 120_000

    public static func make(pin: String, iterations: Int = defaultIterations) -> PINRecord {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        return PINRecord(salt: salt, hash: derive(pin, salt: salt, iterations: iterations), iterations: iterations)
    }

    public func matches(_ pin: String) -> Bool {
        let candidate = Self.derive(pin, salt: salt, iterations: iterations)
        // Constant-time comparison.
        guard candidate.count == hash.count else { return false }
        return zip(candidate, hash).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func derive(_ pin: String, salt: Data, iterations: Int) -> Data {
        let password = Array(pin.utf8)
        var output = [UInt8](repeating: 0, count: 32)
        salt.withUnsafeBytes { saltBytes in
            _ = password.withUnsafeBufferPointer { passwordBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) }, password.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                    &output, output.count)
            }
        }
        return Data(output)
    }

    /// 4–6 ASCII digits.
    public static func isValid(_ pin: String) -> Bool {
        (4...6).contains(pin.count) && pin.allSatisfy { $0.isASCII && $0.isNumber }
    }
}

/// Persisted brute-force state, so restarting the app does not reset the lockout.
public struct PINAttemptState: Codable, Equatable, Sendable {
    public var failures: Int = 0
    public var lockedUntil: Date?
    public init(failures: Int = 0, lockedUntil: Date? = nil) {
        self.failures = failures
        self.lockedUntil = lockedUntil
    }
}

public protocol PINStore: Sendable {
    func loadRecord() throws -> PINRecord?
    func saveRecord(_ record: PINRecord?) throws
    func loadAttempts() throws -> PINAttemptState
    func saveAttempts(_ state: PINAttemptState) throws
}

/// Keychain storage: `WhenUnlockedThisDeviceOnly`, never in backups or on other devices.
public struct KeychainPINStore: PINStore {
    private let service: String

    public init(service: String = "parental-pin.v1") {
        self.service = service
    }

    private func query(_ account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        #if os(iOS) || os(tvOS) || os(visionOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    private func read(_ account: String) throws -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStoreError(status: status) }
        return result as? Data
    }

    private func write(_ data: Data?, account: String) throws {
        let query = query(account)
        guard let data else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialStoreError(status: status) }
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw CredentialStoreError(status: update) }
        let add = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        guard add == errSecSuccess else { throw CredentialStoreError(status: add) }
    }

    public func loadRecord() throws -> PINRecord? {
        try read("pin").map { try JSONDecoder().decode(PINRecord.self, from: $0) }
    }

    public func saveRecord(_ record: PINRecord?) throws {
        try write(record.map { try JSONEncoder().encode($0) }, account: "pin")
    }

    public func loadAttempts() throws -> PINAttemptState {
        try read("attempts").map { try JSONDecoder().decode(PINAttemptState.self, from: $0) } ?? PINAttemptState()
    }

    public func saveAttempts(_ state: PINAttemptState) throws {
        try write(state == PINAttemptState() ? nil : try JSONEncoder().encode(state), account: "attempts")
    }
}

public final class InMemoryPINStore: PINStore, @unchecked Sendable {
    private let lock = NSLock()
    private var record: PINRecord?
    private var attempts = PINAttemptState()

    public init() {}

    public func loadRecord() throws -> PINRecord? { lock.withLock { record } }
    public func saveRecord(_ record: PINRecord?) throws { lock.withLock { self.record = record } }
    public func loadAttempts() throws -> PINAttemptState { lock.withLock { attempts } }
    public func saveAttempts(_ state: PINAttemptState) throws { lock.withLock { attempts = state } }
}
