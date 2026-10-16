import Foundation
import Security

public protocol CredentialStore: Sendable {
    func save(_ credentials: XtreamCredentials, for sourceID: UUID) throws
    func load(for sourceID: UUID) throws -> XtreamCredentials?
    func delete(for sourceID: UUID) throws
    /// Source IDs that currently have stored credentials (used to remove orphans).
    func storedSourceIDs() throws -> [UUID]
}

public struct CredentialStoreError: Error, Equatable, Sendable {
    public let status: OSStatus
}

/// Keychain-backed credential storage.
///
/// Accessibility: `AfterFirstUnlockThisDeviceOnly` — readable after the first unlock so a
/// future background refresh can work, never migrated to backups or other devices.
/// The service name is deliberately brand-neutral so a rename does not orphan credentials.
public struct KeychainCredentialStore: CredentialStore {
    public static let defaultService = "provider-credentials.v1"
    private let service: String

    public init(service: String = KeychainCredentialStore.defaultService) {
        self.service = service
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        #if os(iOS) || os(tvOS) || os(visionOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    public func save(_ credentials: XtreamCredentials, for sourceID: UUID) throws {
        let data = try JSONEncoder().encode(credentials)
        var query = baseQuery()
        query[kSecAttrAccount as String] = sourceID.uuidString
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw CredentialStoreError(status: updateStatus) }
        query.merge(attributes) { $1 }
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw CredentialStoreError(status: addStatus) }
    }

    public func load(for sourceID: UUID) throws -> XtreamCredentials? {
        var query = baseQuery()
        query[kSecAttrAccount as String] = sourceID.uuidString
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CredentialStoreError(status: status) }
        return try JSONDecoder().decode(XtreamCredentials.self, from: data)
    }

    public func delete(for sourceID: UUID) throws {
        var query = baseQuery()
        query[kSecAttrAccount as String] = sourceID.uuidString
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialStoreError(status: status) }
    }

    public func storedSourceIDs() throws -> [UUID] {
        var query = baseQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { throw CredentialStoreError(status: status) }
        return items.compactMap { ($0[kSecAttrAccount as String] as? String).flatMap(UUID.init(uuidString:)) }
    }
}

/// In-memory store for tests and previews.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: XtreamCredentials] = [:]

    public init() {}

    public func save(_ credentials: XtreamCredentials, for sourceID: UUID) throws {
        lock.withLock { storage[sourceID] = credentials }
    }

    public func load(for sourceID: UUID) throws -> XtreamCredentials? {
        lock.withLock { storage[sourceID] }
    }

    public func delete(for sourceID: UUID) throws {
        lock.withLock { _ = storage.removeValue(forKey: sourceID) }
    }

    public func storedSourceIDs() throws -> [UUID] {
        lock.withLock { Array(storage.keys) }
    }
}
