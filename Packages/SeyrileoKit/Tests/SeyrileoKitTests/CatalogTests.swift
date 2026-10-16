import Foundation
import GRDB
import Testing
@testable import SeyrileoFixtureServer
@testable import SeyrileoKit

enum CatalogFixtures {
    static func source(_ name: String = "Home", id: UUID = UUID()) -> ProviderSource {
        ProviderSource(id: id, name: name, kind: .xtream, serverURL: URL(string: "https://tv.example.com")!)
    }

    static func snapshot(
        _ sourceID: UUID, channels: [(id: String, name: String, categories: [String])],
        categories: [(id: String, name: String)] = [("1", "Ulusal"), ("2", "Spor")]
    ) -> LiveCatalogSnapshot {
        LiveCatalogSnapshot(
            account: AccountInfo(status: .active, maxConnections: 2, allowedOutputFormats: ["m3u8", "ts"]),
            categories: CatalogPage(
                items: categories.map { LiveCategory(providerID: sourceID, remoteID: $0.id, name: $0.name) }, droppedCount: 0),
            channels: CatalogPage(
                items: channels.map {
                    LiveChannel(
                        key: MediaKey(providerID: sourceID, kind: .live, remoteID: $0.id), name: $0.name, number: nil,
                        categoryIDs: $0.categories, iconURL: nil, epgChannelID: nil, advertisesArchive: false)
                },
                droppedCount: 1))
    }

    static let standard: [(id: String, name: String, categories: [String])] = [
        ("10", "|TR| TRT 1 HD", ["1"]),
        ("11", "|TR| Çağrı TV", ["1"]),
        ("12", "İZMİR TV", ["1"]),
        ("20", "BEIN SPORTS 1", ["2"]),
        ("21", "Beın Haber", ["1", "2"]),
        ("22", "ışık fm", ["2"]),
    ]
}

struct TestBed {
    let database: AppDatabase
    let sources: DatabaseSourceStore
    let catalog: CatalogStore
    let library: LibraryStore

    init() throws {
        database = try AppDatabase.inMemory()
        sources = DatabaseSourceStore(database: database)
        catalog = CatalogStore(database: database)
        library = LibraryStore(database: database)
    }

    @discardableResult
    func addSource(_ source: ProviderSource = CatalogFixtures.source()) throws -> ProviderSource {
        try sources.saveSources(try sources.loadSources() + [source])
        return source
    }

    func searchRowCount(_ sourceID: UUID) throws -> Int {
        try database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM liveChannelSearch WHERE sourceID = ?", arguments: [sourceID.uuidString]) ?? -1
        }
    }
}

@Suite struct MigrationTests {
    @Test func createdAtRoundTripIsStableForAnyValue() throws {
        for seconds in [0.1, 813_745_913.382932, 1_760_000_000.123456789, 2_000_000_000.999] {
            let bed = try TestBed()
            let source = ProviderSource(name: "S", kind: .xtream, serverURL: URL(string: "https://x.example")!, createdAt: Date(timeIntervalSinceReferenceDate: seconds))
            try bed.addSource(source)
            #expect(try bed.sources.loadSources() == [source])
        }
    }

    @Test func migrationsAreAppliedOnceAndDataSurvivesReopen() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("seyrileo-db-\(UUID().uuidString)/catalog.sqlite")
        let source = CatalogFixtures.source()
        do {
            let database = try AppDatabase.onDisk(at: url)
            try DatabaseSourceStore(database: database).saveSources([source])
            let applied = try database.writer.read { try AppDatabase.migrator.appliedIdentifiers($0) }
            #expect(applied == Set(AppDatabase.migrationIdentifiers))
        }
        let reopened = try AppDatabase.onDisk(at: url)
        #expect(try DatabaseSourceStore(database: reopened).loadSources() == [source])
        let hasCompleted = try reopened.writer.read { try AppDatabase.migrator.hasCompletedMigrations($0) }
        #expect(hasCompleted)
    }

    @Test func legacyJSONSourcesAreImportedOnce() throws {
        let bed = try TestBed()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("seyrileo-json-\(UUID().uuidString)")
        let json = directory.appendingPathComponent("sources.json")
        let a = CatalogFixtures.source("A"), b = CatalogFixtures.source("B")
        try FileSourceStore(fileURL: json).saveSources([a, b])
        try bed.addSource(a)  // already present: must not duplicate

        #expect(try bed.sources.importLegacyJSON(at: json) == 1)
        #expect(Set(try bed.sources.loadSources().map(\.id)) == [a.id, b.id])
        #expect(!FileManager.default.fileExists(atPath: json.path))
        #expect(FileManager.default.fileExists(atPath: json.appendingPathExtension("imported").path))
        #expect(try bed.sources.importLegacyJSON(at: json) == 0)
    }
}

@Suite struct CatalogRefreshTests {
    @Test func refreshStoresCatalogInProviderOrder() async throws {
        let bed = try TestBed()
        let source = try bed.addSource()
        let outcome = try await bed.catalog.refresh(sourceID: source.id) {
            CatalogFixtures.snapshot(source.id, channels: CatalogFixtures.standard)
        }
        #expect(outcome == .applied(categories: 2, channels: 6))
        let categories = try await bed.catalog.categories(sourceID: source.id)
        #expect(categories.map(\.category.name) == ["Ulusal", "Spor"])
        #expect(categories.map(\.channelCount) == [4, 3])
        let spor = try await bed.catalog.channels(sourceID: source.id, categoryID: "2")
        #expect(spor.map(\.key.remoteID) == ["20", "21", "22"])
        #expect(spor[1].categoryIDs.sorted() == ["1", "2"])
        let status = try #require(try await bed.catalog.status(sourceID: source.id))
        #expect(status.hasCatalog)
        #expect(status.channelCount == 6)
        #expect(status.droppedCount == 1)
        #expect(status.account?.status == .active)
        #expect(status.account?.preferredLiveFormat == .hls)
        #expect(status.lastErrorCode == nil)
    }

    @Test func failedRefreshKeepsCatalogAndRecordsError() async throws {
        let bed = try TestBed()
        let source = try bed.addSource()
        let first = Date(timeIntervalSince1970: 1000)
        try await bed.catalog.refresh(sourceID: source.id, now: { first }) {
            CatalogFixtures.snapshot(source.id, channels: CatalogFixtures.standard)
        }
        await #expect(throws: XtreamError.transport(.timedOut)) {
            try await bed.catalog.refresh(sourceID: source.id, now: { Date(timeIntervalSince1970: 2000) }) {
                throw XtreamError.transport(.timedOut)
            }
        }
        #expect(try await bed.catalog.categories(sourceID: source.id).count == 2)
        #expect(try await bed.catalog.channels(sourceID: source.id, categoryID: "1").count == 4)
        let status = try #require(try await bed.catalog.status(sourceID: source.id))
        #expect(status.lastSuccessAt == first)
        #expect(status.lastAttemptAt == Date(timeIntervalSince1970: 2000))
        #expect(status.lastErrorCode?.hasPrefix("xtream:") == true)
        #expect(try bed.searchRowCount(source.id) == 6)
    }

    @Test func cancelledRefreshWritesNothing() async throws {
        let bed = try TestBed()
        let source = try bed.addSource()
        try await bed.catalog.refresh(sourceID: source.id) {
            CatalogFixtures.snapshot(source.id, channels: CatalogFixtures.standard)
        }
        // Cancelled while downloading: the download finishes but the result must be discarded.
        let gate = AsyncGate()
        let catalog = bed.catalog
        let task = Task {
            try await catalog.refresh(sourceID: source.id) {
                await gate.wait()
                return CatalogFixtures.snapshot(source.id, channels: [("99", "Replacement", ["1"])])
            }
        }
        task.cancel()
        await gate.open()
        #expect(try await task.value == .cancelled)
        #expect(try await bed.catalog.channels(sourceID: source.id, categoryID: "1").map(\.key.remoteID) == ["10", "11", "12", "21"])
        #expect(try await bed.catalog.status(sourceID: source.id)?.lastErrorCode == nil)

        let explicit = try await bed.catalog.refresh(sourceID: source.id) { throw CancellationError() }
        #expect(explicit == .cancelled)
        #expect(try bed.searchRowCount(source.id) == 6)
    }

    @Test func providerDuplicatesAreIgnored() async throws {
        let bed = try TestBed()
        let source = try bed.addSource()
        try await bed.catalog.refresh(sourceID: source.id) {
            CatalogFixtures.snapshot(source.id, channels: [("1", "First", ["1"]), ("1", "Duplicate", ["2"])])
        }
        let channel = try #require(try await bed.catalog.channel(MediaKey(providerID: source.id, kind: .live, remoteID: "1")))
        #expect(channel.name == "First")
        #expect(try await bed.catalog.status(sourceID: source.id)?.channelCount == 1)
    }

    @Test func favoritesOrderAndPreferencesSurviveRefresh() async throws {
        let bed = try TestBed()
        let source = try bed.addSource()
        try await bed.catalog.refresh(sourceID: source.id) {
            CatalogFixtures.snapshot(source.id, channels: CatalogFixtures.standard)
        }
        let trt = MediaKey(providerID: source.id, kind: .live, remoteID: "10")
        let bein = MediaKey(providerID: source.id, kind: .live, remoteID: "20")
        #expect(try await bed.library.toggleFavorite(trt, title: "TRT 1"))
        #expect(try await bed.library.toggleFavorite(bein, title: "BEIN"))
        try await bed.library.reorderFavorites(sourceID: source.id, orderedKeys: [bein, trt])
        try await bed.library.setPreference("2", forKey: "lastCategory", sourceID: source.id)
        try await bed.library.recordPlayed(trt, title: "TRT 1")

        // The provider drops BEIN in the next refresh.
        try await bed.catalog.refresh(sourceID: source.id) {
            CatalogFixtures.snapshot(source.id, channels: CatalogFixtures.standard.filter { $0.id != "20" })
        }
        let favorites = try await bed.library.favorites(sourceID: source.id)
        #expect(favorites.map(\.key) == [bein, trt])
        #expect(favorites.map(\.isAvailable) == [false, true])
        #expect(favorites[0].title == "BEIN")
        #expect(try await bed.library.preference(forKey: "lastCategory", sourceID: source.id) == "2")
        #expect(try await bed.library.recents(sourceID: source.id).map(\.key) == [trt])

        // It comes back: the same favorite becomes playable again (matched by ID, never by name).
        try await bed.catalog.refresh(sourceID: source.id) {
            CatalogFixtures.snapshot(source.id, channels: CatalogFixtures.standard)
        }
        #expect(try await bed.library.favorites(sourceID: source.id).allSatisfy(\.isAvailable))
        #expect(try await bed.library.toggleFavorite(bein, title: "BEIN") == false)
        #expect(try await bed.library.favoriteKeys(sourceID: source.id) == [trt])
    }
}

@Suite struct SourceIsolationTests {
    @Test func sameRemoteIDsInTwoSourcesNeverCollide() async throws {
        let bed = try TestBed()
        let a = try bed.addSource(CatalogFixtures.source("A"))
        let b = try bed.addSource(CatalogFixtures.source("B"))
        try await bed.catalog.refresh(sourceID: a.id) { CatalogFixtures.snapshot(a.id, channels: [("1", "Alpha News", ["1"])]) }
        try await bed.catalog.refresh(sourceID: b.id) { CatalogFixtures.snapshot(b.id, channels: [("1", "Beta News", ["1"])]) }

        #expect(try await bed.catalog.search(sourceID: a.id, query: "news").channels.map(\.name) == ["Alpha News"])
        #expect(try await bed.catalog.search(sourceID: b.id, query: "news").channels.map(\.name) == ["Beta News"])
        #expect(try await bed.catalog.search(sourceID: a.id, query: "beta").channels.isEmpty)

        let keyA = MediaKey(providerID: a.id, kind: .live, remoteID: "1")
        try await bed.library.toggleFavorite(keyA, title: "Alpha News")
        #expect(try await bed.library.favoriteKeys(sourceID: a.id) == [keyA])
        #expect(try await bed.library.favoriteKeys(sourceID: b.id).isEmpty)

        // A failing refresh of B leaves A untouched.
        _ = try? await bed.catalog.refresh(sourceID: b.id) { throw XtreamError.httpStatus(503) }
        #expect(try await bed.catalog.channel(keyA)?.name == "Alpha News")
    }

    @Test func removingASourceDeletesEverythingItOwnsIncludingCredentials() async throws {
        let bed = try TestBed()
        let keychain = InMemoryCredentialStore()
        let registry = SourceRegistry(sourceStore: bed.sources, credentialStore: keychain)
        let a = CatalogFixtures.source("A"), b = CatalogFixtures.source("B")
        try registry.add(a, credentials: XtreamCredentials(username: "a", password: "pa"))
        try registry.add(b, credentials: XtreamCredentials(username: "b", password: "pb"))
        for source in [a, b] {
            try await bed.catalog.refresh(sourceID: source.id) { CatalogFixtures.snapshot(source.id, channels: CatalogFixtures.standard) }
            let key = MediaKey(providerID: source.id, kind: .live, remoteID: "10")
            try await bed.library.toggleFavorite(key, title: "TRT")
            try await bed.library.recordPlayed(key, title: "TRT")
            try await bed.library.setPreference("x", forKey: "k", sourceID: source.id)
        }

        try registry.remove(sourceID: a.id)

        #expect(try keychain.load(for: a.id) == nil)
        #expect(try keychain.load(for: b.id) != nil)
        let counts = try await bed.database.writer.read { db in
            try ["liveCategory", "liveChannel", "liveChannelCategory", "liveChannelSearch", "favorite", "recent", "sourcePreference", "catalogState"]
                .map { try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0) WHERE sourceID = ?", arguments: [a.id.uuidString]) ?? -1 }
        }
        #expect(counts.allSatisfy { $0 == 0 }, "\(counts)")
        #expect(try bed.searchRowCount(b.id) == 6)
        #expect(try await bed.library.favoriteKeys(sourceID: b.id).count == 1)
    }
}

@Suite struct TurkishSearchTests {
    @Test(arguments: [
        ("ÇAĞRI", "cagri"), ("çağrı", "cagri"), ("İZMİR", "izmir"), ("ışık", "isik"), ("IŞIK", "isik"),
        ("Beın", "bein"), ("BEIN", "bein"), ("|TR| Trt-1 HD", "tr trt 1 hd"), ("  Şov   TV ", "sov tv"), ("Ünlü Öykü", "unlu oyku"),
    ])
    func normalization(input: String, expected: String) {
        #expect(SearchText.normalize(input) == expected)
    }

    @Test func ftsQueryEscapesAndPrefixes() {
        #expect(SearchText.ftsPrefixQuery("Trt 1") == "\"trt\"* \"1\"*")
        #expect(SearchText.ftsPrefixQuery("a\"b OR c") == "\"a\"* \"b\"* \"or\"* \"c\"*")
        #expect(SearchText.ftsPrefixQuery("  |- ") == nil)
    }

    @Test(arguments: [
        ("cagri", ["11"]), ("ÇAĞRI", ["11"]), ("Çağ", ["11"]),
        ("izmir", ["12"]), ("İZMİR", ["12"]), ("IZMIR", ["12"]),
        ("bein", ["20", "21"]), ("BEİN", ["20", "21"]), ("beın", ["20", "21"]),
        ("isik", ["22"]), ("IŞIK", ["22"]),
        ("trt 1", ["10"]), ("tr", ["10", "11"]), ("haber bein", ["21"]), ("xyz", []),
    ])
    func searchIsCaseAndDiacriticInsensitive(query: String, expected: [String]) async throws {
        let bed = try TestBed()
        let source = try bed.addSource()
        try await bed.catalog.refresh(sourceID: source.id) { CatalogFixtures.snapshot(source.id, channels: CatalogFixtures.standard) }
        let result = try await bed.catalog.search(sourceID: source.id, query: query)
        #expect(result.channels.map(\.key.remoteID) == expected)
    }

    @Test func categoryFilterAndTruncation() async throws {
        let bed = try TestBed()
        let source = try bed.addSource()
        try await bed.catalog.refresh(sourceID: source.id) { CatalogFixtures.snapshot(source.id, channels: CatalogFixtures.standard) }
        #expect(try await bed.catalog.search(sourceID: source.id, query: "bein", categoryID: "1").channels.map(\.key.remoteID) == ["21"])
        #expect(try await bed.catalog.search(sourceID: source.id, query: "trt", categoryID: "2").channels.isEmpty)
        let truncated = try await bed.catalog.search(sourceID: source.id, query: "tv", limit: 1)
        #expect(truncated.channels.count == 1)
        #expect(truncated.isTruncated)
    }

    @MainActor
    @Test func debounceRunsOnlyTheLastQuery() async throws {
        let bed = try TestBed()
        let source = try bed.addSource()
        try await bed.catalog.refresh(sourceID: source.id) { CatalogFixtures.snapshot(source.id, channels: CatalogFixtures.standard) }
        let gate = AsyncGate()
        let controller = ChannelSearchController(sourceID: source.id, store: bed.catalog, sleeper: { _ in await gate.wait() })
        controller.query = "t"
        controller.query = "tr"
        controller.query = "trt"
        #expect(controller.phase == .searching)
        let last = controller.pending
        await gate.open()
        await last?.value
        #expect(controller.executedQueries == ["trt"])
        guard case .results(let channels, false) = controller.phase else {
            Issue.record("expected results, got \(controller.phase)")
            return
        }
        #expect(channels.map(\.key.remoteID) == ["10"])
        controller.query = " | "
        #expect(controller.phase == .idle)
    }
}

@Suite struct RecentsTests {
    @Test func recentsAreOrderedDedupedAndCapped() async throws {
        let bed = try TestBed()
        let source = try bed.addSource()
        for index in 0..<(LibraryStore.recentLimit + 5) {
            try await bed.library.recordPlayed(
                MediaKey(providerID: source.id, kind: .live, remoteID: "\(index)"), title: "C\(index)",
                at: Date(timeIntervalSince1970: TimeInterval(index)))
        }
        let again = MediaKey(providerID: source.id, kind: .live, remoteID: "10")
        try await bed.library.recordPlayed(again, title: "C10", at: Date(timeIntervalSince1970: 10_000))
        let recents = try await bed.library.recents(sourceID: source.id, limit: 100)
        #expect(recents.count == LibraryStore.recentLimit)
        #expect(recents.first?.key == again)
        #expect(Set(recents.map(\.key)).count == recents.count)
        #expect(recents.allSatisfy { !$0.isAvailable })  // no catalogue loaded: honest "unavailable"
    }
}

@Suite(.serialized) struct FixtureCatalogIntegrationTests {
    @Test func refreshFromLoopbackProviderIntoDatabase() async throws {
        let server = try FixtureServer(port: 0)
        try await server.start()
        defer { server.stop() }
        let bed = try TestBed()
        let source = try bed.addSource(ProviderSource(name: "Fixture", kind: .fixture, serverURL: try #require(server.baseURL)))
        let client = XtreamClient(
            providerID: source.id, endpoint: try XtreamEndpoint(baseURL: source.serverURL),
            credentials: XtreamCredentials(username: FixtureServer.username, password: FixtureServer.password),
            transport: URLSessionTransport(), retryPolicy: .none)
        let outcome = try await bed.catalog.refresh(sourceID: source.id) { try await client.fetchLiveSnapshot() }
        #expect(outcome == .applied(categories: 2, channels: 7))
        #expect(try await bed.catalog.search(sourceID: source.id, query: "pattern").channels.count == 2)
        #expect(try await bed.catalog.status(sourceID: source.id)?.droppedCount == 2)
    }
}
