import Foundation

/// Keeps source configuration and Keychain credentials consistent.
/// Credentials are written first and rolled back if the configuration write fails, and
/// removing a source removes its credentials.
public struct SourceRegistry: Sendable {
    private let sourceStore: SourceStore
    private let credentialStore: CredentialStore

    public init(sourceStore: SourceStore, credentialStore: CredentialStore) {
        self.sourceStore = sourceStore
        self.credentialStore = credentialStore
    }

    public func sources() throws -> [ProviderSource] {
        try sourceStore.loadSources()
    }

    public func credentials(for source: ProviderSource) throws -> XtreamCredentials? {
        try credentialStore.load(for: source.id)
    }

    @discardableResult
    public func add(_ source: ProviderSource, credentials: XtreamCredentials) throws -> [ProviderSource] {
        var sources = try sourceStore.loadSources()
        try credentialStore.save(credentials, for: source.id)
        sources.removeAll { $0.id == source.id }
        sources.append(source)
        do {
            try sourceStore.saveSources(sources)
        } catch {
            try? credentialStore.delete(for: source.id)
            throw error
        }
        return sources
    }

    @discardableResult
    public func remove(sourceID: UUID) throws -> [ProviderSource] {
        var sources = try sourceStore.loadSources()
        sources.removeAll { $0.id == sourceID }
        try sourceStore.saveSources(sources)
        try credentialStore.delete(for: sourceID)
        return sources
    }

    /// Deletes Keychain items whose source no longer exists (for example after an
    /// interrupted removal, or a reinstall: iOS Keychain items survive app deletion).
    public func pruneOrphanedCredentials() throws {
        let known = Set(try sourceStore.loadSources().map(\.id))
        for id in try credentialStore.storedSourceIDs() where !known.contains(id) {
            try credentialStore.delete(for: id)
        }
    }
}
