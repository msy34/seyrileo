import Foundation
import Testing
@testable import SeyrileoKit

@Suite struct SourceRegistryTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("seyrileo-tests-\(UUID().uuidString)")
    var fileURL: URL { directory.appendingPathComponent("sources.json") }
    let credentials = XtreamCredentials(username: "alice", password: "Pa55/w0rd?")

    func source(_ name: String = "Home") -> ProviderSource {
        ProviderSource(name: name, kind: .xtream, serverURL: URL(string: "https://tv.example.com")!)
    }

    @Test func persistsAcrossInstancesWithoutSecretsInFile() throws {
        let keychain = InMemoryCredentialStore()
        let source = source()
        try SourceRegistry(sourceStore: FileSourceStore(fileURL: fileURL), credentialStore: keychain).add(source, credentials: credentials)

        let reopened = SourceRegistry(sourceStore: FileSourceStore(fileURL: fileURL), credentialStore: keychain)
        #expect(try reopened.sources() == [source])
        #expect(try reopened.credentials(for: source) == credentials)

        let raw = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(!raw.contains("Pa55"))
        #expect(!raw.contains("alice"))
        #expect(raw.contains("\"schemaVersion\" : 1"))
    }

    @Test func removeDeletesCredentials() throws {
        let keychain = InMemoryCredentialStore()
        let registry = SourceRegistry(sourceStore: FileSourceStore(fileURL: fileURL), credentialStore: keychain)
        let source = source()
        try registry.add(source, credentials: credentials)
        try registry.remove(sourceID: source.id)
        #expect(try registry.sources().isEmpty)
        #expect(try keychain.load(for: source.id) == nil)
    }

    @Test func failedConfigWriteRollsBackCredentials() throws {
        struct FailingStore: SourceStore {
            func loadSources() throws -> [ProviderSource] { [] }
            func saveSources(_ sources: [ProviderSource]) throws { throw CocoaError(.fileWriteNoPermission) }
        }
        let keychain = InMemoryCredentialStore()
        let registry = SourceRegistry(sourceStore: FailingStore(), credentialStore: keychain)
        #expect(throws: CocoaError.self) { try registry.add(source(), credentials: credentials) }
        #expect(try keychain.storedSourceIDs().isEmpty)
    }

    @Test func prunesOrphanedCredentials() throws {
        let keychain = InMemoryCredentialStore()
        let registry = SourceRegistry(sourceStore: FileSourceStore(fileURL: fileURL), credentialStore: keychain)
        let kept = source("Kept")
        try registry.add(kept, credentials: credentials)
        let orphan = UUID()
        try keychain.save(credentials, for: orphan)
        try registry.pruneOrphanedCredentials()
        #expect(try keychain.storedSourceIDs() == [kept.id])
    }

    @Test func refusesNewerSchema() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":99,"sources":[]}"#.utf8).write(to: fileURL)
        #expect(throws: FileSourceStore.StoreError.unsupportedSchemaVersion(99)) {
            try FileSourceStore(fileURL: fileURL).loadSources()
        }
    }

    #if os(iOS)
    /// Needs a host with a keychain entitlement. SwiftPM test bundles on the simulator have
    /// none (errSecMissingEntitlement, -34018), so this runs only where the probe succeeds;
    /// the app-level relaunch check in docs/REQUIREMENTS.md covers the real path.
    @Test(.enabled(if: KeychainProbe.isAvailable, "No keychain entitlement in this test host"))
    func keychainRoundTrip() throws {
        let store = KeychainCredentialStore(service: "provider-credentials.tests.\(UUID().uuidString)")
        let id = UUID()
        try store.save(credentials, for: id)
        #expect(try store.load(for: id) == credentials)
        let updated = XtreamCredentials(username: "alice", password: "new")
        try store.save(updated, for: id)
        #expect(try store.load(for: id) == updated)
        #expect(try store.storedSourceIDs() == [id])
        try store.delete(for: id)
        #expect(try store.load(for: id) == nil)
    }
    #endif
}

#if os(iOS)
enum KeychainProbe {
    static let isAvailable: Bool = {
        let store = KeychainCredentialStore(service: "provider-credentials.probe")
        let id = UUID()
        defer { try? store.delete(for: id) }
        return (try? store.save(XtreamCredentials(username: "p", password: "p"), for: id)) != nil
    }()
}
#endif
