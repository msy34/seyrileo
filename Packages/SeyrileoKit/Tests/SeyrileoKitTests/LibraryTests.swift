import Foundation
import GRDB
import Testing
@testable import SeyrileoFixtureServer
@testable import SeyrileoKit

@Suite struct LibraryDecodingTests {
    @Test func vodListToleratesTypesAndCountsBadEntries() async throws {
        let json = #"[{"stream_id":1,"name":" A ","container_extension":"MP4","added":"1700000000","category_id":"3","rating":""},{"stream_id":"2","name":"B","container_extension":"../x","category_ids":[3,4]},{"name":"no id"}]"#
        let page = try await XtreamClient.stub(StubTransport.json(json)).vodStreams()
        #expect(page.items.map(\.key.remoteID) == ["1", "2"])
        #expect(page.droppedCount == 1)
        #expect(page.items[0].name == "A")
        #expect(page.items[0].containerExtension == "mp4")
        #expect(page.items[0].rating == nil)
        #expect(page.items[0].addedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(page.items[1].containerExtension == nil)  // unsafe value rejected, not guessed
        #expect(page.items[1].categoryIDs == ["3", "4"])
        #expect(page.items.allSatisfy { $0.key.kind == .movie })
    }

    @Test func vodInfoWithEmptyInfoArray() async throws {
        let client = try XtreamClient.stub(StubTransport.json(#"{"info":[],"movie_data":{"stream_id":7}}"#))
        let detail = try await client.movieDetail(MediaKey(providerID: client.providerID, kind: .movie, remoteID: "7"))
        #expect(detail.plot == nil)
        #expect(detail.durationSeconds == nil)
        #expect(detail.containerExtension == nil)
    }

    @Test func detailNotFoundIsAnError() async throws {
        let client = try XtreamClient.stub(StubTransport.json("[]"))
        await #expect(throws: XtreamError.unexpectedShape("detail: not an object")) {
            try await client.movieDetail(MediaKey(providerID: client.providerID, kind: .movie, remoteID: "7"))
        }
    }

    @Test func seriesInfoWithKeyedEpisodesIsOrdered() async throws {
        let client = try XtreamClient.stub(StubTransport.json(FixtureCatalog.seriesInfoJSON(id: "401")))
        let key = MediaKey(providerID: client.providerID, kind: .series, remoteID: "401")
        let detail = try await client.seriesDetail(key)
        #expect(detail.seasons.map(\.number) == [1, 2])
        #expect(detail.seasons[0].name == "Season 1")
        #expect(detail.seasons[0].episodes.map(\.key.remoteID) == ["501", "502"])
        #expect(detail.seasons[1].episodes.map(\.title) == ["S2 E1"])
        #expect(detail.droppedEpisodes == 1)
        #expect(detail.allEpisodes.allSatisfy { $0.seriesKey == key && $0.key.kind == .episode })
        #expect(detail.episode(after: detail.seasons[0].episodes[1].key)?.key.remoteID == "503")
        #expect(detail.episode(after: detail.seasons[1].episodes[0].key) == nil)
    }

    @Test func seriesInfoWithNestedArraysAndEmptyInfo() async throws {
        let json = #"{"info":[],"episodes":[[{"id":"9","season":3,"container_extension":"mkv"}],[{"id":"8","season":1}]]}"#
        let client = try XtreamClient.stub(StubTransport.json(json))
        let detail = try await client.seriesDetail(MediaKey(providerID: client.providerID, kind: .series, remoteID: "1"))
        #expect(detail.seasons.map(\.number) == [1, 3])
        #expect(detail.seasons[0].episodes[0].containerExtension == nil)
        #expect(detail.name == nil)
        #expect(try await XtreamClient.stub(StubTransport.json(FixtureCatalog.seriesInfoJSON(id: "402")))
            .seriesDetail(MediaKey(providerID: client.providerID, kind: .series, remoteID: "402")).seasons.isEmpty)
    }

    @Test func onDemandURLsEncodeCredentialsAndNeverGuessContainers() throws {
        let client = try XtreamClient.stub(StubTransport.json("[]"), credentials: XtreamCredentials(username: "u/1", password: "p#?"))
        let movie = MediaKey(providerID: client.providerID, kind: .movie, remoteID: "42")
        #expect(try client.movieStreamURL(movie, containerExtension: "mkv").absoluteString
            == "https://provider.example:8443/base/movie/u%2F1/p%23%3F/42.mkv")
        #expect(throws: LibraryPlaybackError.unknownContainer) { try client.movieStreamURL(movie, containerExtension: nil) }
        #expect(throws: LibraryPlaybackError.unknownContainer) { try client.movieStreamURL(movie, containerExtension: "m p4") }
        let episode = Episode(
            key: MediaKey(providerID: client.providerID, kind: .episode, remoteID: "7"), seriesKey: movie, seasonNumber: 1,
            episodeNumber: 1, title: "", plot: nil, durationSeconds: nil, stillURL: nil, containerExtension: "mp4")
        #expect(try client.episodeStreamURL(episode).absoluteString == "https://provider.example:8443/base/series/u%2F1/p%23%3F/7.mp4")
        let redacted = client.redactor.redact(try client.episodeStreamURL(episode).absoluteString)
        #expect(redacted == "https://provider.example:8443/[redacted]")
    }
}

enum LibraryFixtures {
    static func snapshot(_ sourceID: UUID, movies: [(String, String, [String])] = [("1", "Çağrı Filmi", ["10"]), ("2", "İstanbul Masalı", ["10", "11"])],
                         series: [(String, String, [String])] = [("7", "Ihlamur Dizisi", ["20"])]) -> LibrarySnapshot {
        LibrarySnapshot(
            movieCategories: CatalogPage(items: [
                MediaCategory(providerID: sourceID, kind: .movie, remoteID: "10", name: "Dram"),
                MediaCategory(providerID: sourceID, kind: .movie, remoteID: "11", name: "Komedi"),
            ], droppedCount: 0),
            movies: CatalogPage(items: movies.map {
                Movie(key: MediaKey(providerID: sourceID, kind: .movie, remoteID: $0.0), name: $0.1, posterURL: nil,
                      rating: nil, addedAt: nil, categoryIDs: $0.2, containerExtension: "mp4")
            }, droppedCount: 1),
            seriesCategories: CatalogPage(items: [MediaCategory(providerID: sourceID, kind: .series, remoteID: "20", name: "Yerli")], droppedCount: 0),
            series: CatalogPage(items: series.map {
                Series(key: MediaKey(providerID: sourceID, kind: .series, remoteID: $0.0), name: $0.1, posterURL: nil,
                       plot: nil, genre: nil, rating: nil, releaseDate: nil, categoryIDs: $0.2)
            }, droppedCount: 0))
    }
}

@Suite struct LibraryStoreTests {
    @Test func refreshStoresMoviesSeriesAndCounts() async throws {
        let bed = try TestBed()
        let source = try bed.addSource()
        let store = LibraryCatalogStore(database: bed.database)
        #expect(try await store.refresh(sourceID: source.id) { LibraryFixtures.snapshot(source.id) } == .applied(categories: 3, channels: 3))
        #expect(try await store.categories(sourceID: source.id, kind: .movie).map(\.itemCount) == [2, 1])
        #expect(try await store.items(sourceID: source.id, kind: .movie, categoryID: "11").map(\.key.remoteID) == ["2"])
        #expect(try await store.items(sourceID: source.id, kind: .series, categoryID: "20").map(\.name) == ["Ihlamur Dizisi"])
        let status = try #require(try await store.status(sourceID: source.id))
        #expect(status.movieCount == 2 && status.seriesCount == 1 && status.droppedCount == 1)
        #expect(try await store.movie(MediaKey(providerID: source.id, kind: .movie, remoteID: "1"))?.containerExtension == "mp4")
    }

    @Test func turkishSearchInMoviesAndSeries() async throws {
        let bed = try TestBed()
        let source = try bed.addSource()
        let store = LibraryCatalogStore(database: bed.database)
        try await store.refresh(sourceID: source.id) { LibraryFixtures.snapshot(source.id) }
        #expect(try await store.search(sourceID: source.id, kind: .movie, query: "cagri").items.map(\.key.remoteID) == ["1"])
        #expect(try await store.search(sourceID: source.id, kind: .movie, query: "ISTANBUL").items.map(\.key.remoteID) == ["2"])
        #expect(try await store.search(sourceID: source.id, kind: .movie, query: "istanbul", categoryID: "10").items.count == 1)
        #expect(try await store.search(sourceID: source.id, kind: .series, query: "ıhlamur").items.map(\.name) == ["Ihlamur Dizisi"])
        #expect(try await store.search(sourceID: source.id, kind: .series, query: "cagri").items.isEmpty)
    }

    @Test func failedOrCancelledRefreshKeepsLibrary() async throws {
        let bed = try TestBed()
        let source = try bed.addSource()
        let store = LibraryCatalogStore(database: bed.database)
        try await store.refresh(sourceID: source.id) { LibraryFixtures.snapshot(source.id) }
        await #expect(throws: XtreamError.httpStatus(503)) {
            try await store.refresh(sourceID: source.id) { throw XtreamError.httpStatus(503) }
        }
        #expect(try await store.refresh(sourceID: source.id) { throw CancellationError() } == .cancelled)
        #expect(try await store.status(sourceID: source.id)?.movieCount == 2)
        #expect(try await store.status(sourceID: source.id)?.lastErrorCode?.hasPrefix("xtream:") == true)
        #expect(try await store.search(sourceID: source.id, kind: .movie, query: "cagri").items.count == 1)
    }

    @Test func liveAndLibraryRefreshesDoNotTouchEachOthersIndex() async throws {
        let bed = try TestBed()
        let source = try bed.addSource()
        let library = LibraryCatalogStore(database: bed.database)
        try await library.refresh(sourceID: source.id) { LibraryFixtures.snapshot(source.id) }
        try await bed.catalog.refresh(sourceID: source.id) { CatalogFixtures.snapshot(source.id, channels: CatalogFixtures.standard) }
        #expect(try await library.search(sourceID: source.id, kind: .movie, query: "cagri").items.count == 1)
        try await library.refresh(sourceID: source.id) { LibraryFixtures.snapshot(source.id, movies: []) }
        #expect(try await bed.catalog.search(sourceID: source.id, query: "cagri").channels.map(\.key.remoteID) == ["11"])
    }

    @Test func librariesAreIsolatedPerSourceAndRemovedWithIt() async throws {
        let bed = try TestBed()
        let keychain = InMemoryCredentialStore()
        let registry = SourceRegistry(sourceStore: bed.sources, credentialStore: keychain)
        let a = CatalogFixtures.source("A"), b = CatalogFixtures.source("B")
        try registry.add(a, credentials: XtreamCredentials(username: "a", password: "pa"))
        try registry.add(b, credentials: XtreamCredentials(username: "b", password: "pb"))
        let store = LibraryCatalogStore(database: bed.database)
        let progress = ProgressStore(database: bed.database)
        try await store.refresh(sourceID: a.id) { LibraryFixtures.snapshot(a.id) }
        try await store.refresh(sourceID: b.id) { LibraryFixtures.snapshot(b.id, movies: [("1", "Başka Film", ["10"])]) }
        let keyA = MediaKey(providerID: a.id, kind: .movie, remoteID: "1")
        try await progress.save(PlaybackProgress(key: keyA, title: "Çağrı Filmi", position: 600, duration: 5400))
        #expect(try await progress.progress(MediaKey(providerID: b.id, kind: .movie, remoteID: "1")) == nil)
        #expect(try await store.movie(MediaKey(providerID: b.id, kind: .movie, remoteID: "1"))?.name == "Başka Film")

        try registry.remove(sourceID: a.id)
        let leftovers = try await bed.database.writer.read { db in
            try ["mediaCategory", "movie", "series", "mediaMembership", "mediaSearch", "libraryState", "playbackProgress"]
                .map { try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0) WHERE sourceID = ?", arguments: [a.id.uuidString]) ?? -1 }
        }
        #expect(leftovers.allSatisfy { $0 == 0 }, "\(leftovers)")
        #expect(try await store.status(sourceID: b.id)?.movieCount == 1)
    }

    @Test func migrationFromV1KeepsExistingData() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in try db.execute(sql: "PRAGMA foreign_keys = ON") }
        var v1 = DatabaseMigrator()
        // Apply only the first migration, as an existing Milestone 2 install would have.
        let full = AppDatabase.migrator
        v1 = full
        try v1.migrate(queue, upTo: "v1-catalog")
        let id = UUID()
        try queue.write { db in
            try db.execute(sql: "INSERT INTO source (id, name, kind, serverURL, createdAt, position) VALUES (?, 'Old', 'xtream', 'https://x.example', 0, 0)", arguments: [id.uuidString])
            try db.execute(sql: "INSERT INTO favorite (sourceID, kind, remoteID, titleSnapshot, position, createdAt) VALUES (?, 'live', '5', 'Ch', 1, 0)", arguments: [id.uuidString])
        }
        let database = try AppDatabase(queue)
        let applied = try database.writer.read { try AppDatabase.migrator.appliedIdentifiers($0) }
        #expect(applied == Set(AppDatabase.migrationIdentifiers))
        #expect(try DatabaseSourceStore(database: database).loadSources().map(\.id) == [id])
        #expect(try database.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM favorite") } == 1)
    }
}

@Suite struct ProgressTests {
    @Test(arguments: [
        (10.0, 5400.0, false), (5000.0, 5400.0, false), (5131.0, 5400.0, true), (5320.0, 5400.0, true), (100.0, 120.0, true),
    ])
    func completionPolicy(position: Double, duration: Double, completed: Bool) {
        #expect(ProgressPolicy.isCompleted(position: position, duration: duration) == completed)
    }

    @Test func unknownDurationIsNeverCompleted() {
        #expect(!ProgressPolicy.isCompleted(position: 99_999, duration: nil))
        #expect(!ProgressPolicy.isCompleted(position: 10, duration: .nan))
    }

    @Test func saveUpdateResumeAndContinueWatching() async throws {
        let bed = try TestBed()
        let source = try bed.addSource()
        let store = ProgressStore(database: bed.database)
        let movie = MediaKey(providerID: source.id, kind: .movie, remoteID: "1")
        let series = MediaKey(providerID: source.id, kind: .series, remoteID: "7")
        let e1 = MediaKey(providerID: source.id, kind: .episode, remoteID: "71")
        let e2 = MediaKey(providerID: source.id, kind: .episode, remoteID: "72")

        try await store.save(PlaybackProgress(key: movie, title: "Film", position: 20, duration: 5400, updatedAt: Date(timeIntervalSince1970: 1)))
        #expect(try await store.continueWatching(sourceID: source.id).isEmpty)  // under 30 s: not "started"
        #expect(ProgressPolicy.startPosition(for: try await store.progress(movie)) == 0)

        try await store.save(PlaybackProgress(key: movie, title: "Film", position: 1200, duration: nil, updatedAt: Date(timeIntervalSince1970: 2)))
        #expect(try await store.progress(movie)?.duration == 5400)  // unknown duration keeps the known one
        #expect(ProgressPolicy.startPosition(for: try await store.progress(movie)) == 1200)

        try await store.save(PlaybackProgress(key: e1, title: "E1", seriesKey: series, seriesTitle: "Dizi", seasonNumber: 1, episodeNumber: 1,
                                              position: 300, duration: 2700, updatedAt: Date(timeIntervalSince1970: 3)))
        try await store.save(PlaybackProgress(key: e2, title: "E2", seriesKey: series, seriesTitle: "Dizi", seasonNumber: 1, episodeNumber: 2,
                                              position: 400, duration: 2700, updatedAt: Date(timeIntervalSince1970: 4)))
        let list = try await store.continueWatching(sourceID: source.id)
        #expect(list.map(\.key) == [e2, movie])  // one entry per series: its latest episode
        #expect(try await store.episodeProgress(seriesKey: series).count == 2)

        try await store.save(PlaybackProgress(key: e2, title: "E2", seriesKey: series, position: 2690, duration: 2700, updatedAt: Date(timeIntervalSince1970: 5)))
        #expect(try await store.progress(e2)?.completed == true)
        #expect(try await store.continueWatching(sourceID: source.id).map(\.key) == [e1, movie])

        try await store.remove(movie)
        #expect(try await store.progress(movie) == nil)
    }

    @Test func liveItemsAndInvalidValuesAreIgnored() async throws {
        let bed = try TestBed()
        let source = try bed.addSource()
        let store = ProgressStore(database: bed.database)
        let live = MediaKey(providerID: source.id, kind: .live, remoteID: "1")
        try await store.save(PlaybackProgress(key: live, title: "Live", position: 999, duration: nil))
        try await store.save(PlaybackProgress(key: MediaKey(providerID: source.id, kind: .movie, remoteID: "2"), title: "x", position: .nan, duration: 10))
        try await store.save(PlaybackProgress(key: MediaKey(providerID: UUID(), kind: .movie, remoteID: "3"), title: "orphan", position: 100, duration: 1000))
        let count = try await bed.database.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM playbackProgress") }
        #expect(count == 0)
    }
}

@MainActor
@Suite struct OnDemandCoordinatorTests {
    let ledger = EngineLedger()

    func coordinator() -> PlaybackCoordinator {
        PlaybackCoordinator(factories: [FakeFactory(engineName: "fake", ledger: ledger)], startupTimeout: nil, sleeper: { _ in })
    }

    static func item(_ id: String, start: TimeInterval = 0) -> PlaybackItem {
        PlaybackItem(
            id: MediaKey(providerID: UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!, kind: .movie, remoteID: id),
            title: "Movie \(id)", sourceName: "S", url: URL(string: "http://x.example/movie/u/p/\(id).mp4")!, isLive: false,
            redactor: Redactor(secrets: ["u", "p"]), startPosition: start)
    }

    @Test func startPositionAndRetryContinueFromLastKnownPosition() async {
        let coordinator = coordinator()
        coordinator.play(Self.item("1", start: 600))
        #expect(ledger.created[0].loadedItem?.startPosition == 600)
        ledger.created[0].emitLate(.playing)
        ledger.created[0].emitLate(.progress(position: 900, duration: 5400))
        ledger.created[0].emitLate(.failed(.timedOut))
        await coordinator.pendingRetry?.value
        #expect(ledger.created[1].loadedItem?.startPosition == 900)
    }

    @Test func progressIsReportedPeriodicallyAndOnStopAndSwitch() {
        let coordinator = coordinator()
        var reports: [(String, TimeInterval)] = []
        coordinator.onProgress = { item, position, _ in reports.append((item.id.remoteID, position)) }
        coordinator.play(Self.item("1"))
        ledger.created[0].emitLate(.playing)
        ledger.created[0].emitLate(.progress(position: 35, duration: 100))
        ledger.created[0].progress = (41, 100)
        coordinator.play(Self.item("2"))  // switching saves the first item's final position
        ledger.created[1].emitLate(.playing)
        ledger.created[1].progress = (12, 100)
        coordinator.stop()
        #expect(reports.map(\.0) == ["1", "1", "2"])
        #expect(reports.map(\.1) == [35, 41, 12])
    }

    @Test func liveItemsNeverReportProgressOrResume() {
        let coordinator = coordinator()
        var reports = 0
        coordinator.onProgress = { _, _, _ in reports += 1 }
        let live = PlaybackItem(
            id: MediaKey(providerID: UUID(), kind: .live, remoteID: "1"), title: "L", sourceName: "S",
            url: URL(string: "http://x.example/live/u/p/1.m3u8")!, isLive: true, redactor: Redactor(), startPosition: 500)
        #expect(live.startPosition == 0)
        coordinator.play(live)
        ledger.created[0].emitLate(.playing)
        ledger.created[0].emitLate(.progress(position: 10, duration: nil))
        coordinator.stop()
        #expect(reports == 0)
    }

    @Test func endOfItemReportsFullDurationAndCallsOnEnded() {
        let coordinator = coordinator()
        var ended: [String] = []
        var last: TimeInterval?
        coordinator.onEnded = { ended.append($0.id.remoteID) }
        coordinator.onProgress = { _, position, _ in last = position }
        coordinator.play(Self.item("1"))
        ledger.created[0].emitLate(.playing)
        ledger.created[0].emitLate(.progress(position: 170, duration: 180))
        ledger.created[0].emitLate(.ended)
        #expect(ended == ["1"])
        #expect(last == 180)
        #expect(coordinator.state == .ended)
    }
}

@Suite(.serialized) struct FixtureLibraryIntegrationTests {
    @Test func libraryEndpointsOverLoopback() async throws {
        let server = try FixtureServer(port: 0)
        try await server.start()
        defer { server.stop() }
        let bed = try TestBed()
        let source = try bed.addSource(ProviderSource(name: "Fixture", kind: .fixture, serverURL: try #require(server.baseURL)))
        let client = XtreamClient(
            providerID: source.id, endpoint: try XtreamEndpoint(baseURL: source.serverURL),
            credentials: XtreamCredentials(username: FixtureServer.username, password: FixtureServer.password),
            transport: URLSessionTransport(), retryPolicy: .none)
        let store = LibraryCatalogStore(database: bed.database)
        #expect(try await store.refresh(sourceID: source.id) { try await client.fetchLibrarySnapshot() } == .applied(categories: 2, channels: 6))
        let status = try #require(try await store.status(sourceID: source.id))
        #expect(status.movieCount == 4 && status.seriesCount == 2 && status.droppedCount == 1)

        let film = MediaKey(providerID: source.id, kind: .movie, remoteID: "301")
        let detail = try await client.movieDetail(film)
        #expect(detail.durationSeconds == 180)
        let url = try client.movieStreamURL(film, containerExtension: detail.containerExtension)
        let head = try await URLSessionTransport().get(url, maxBytes: 8 << 20)
        #expect(head.statusCode == 200 && head.contentType == "video/mp4")

        let noContainer = try await client.movieDetail(MediaKey(providerID: source.id, kind: .movie, remoteID: "303"))
        #expect(noContainer.containerExtension == nil)

        let series = try await client.seriesDetail(MediaKey(providerID: source.id, kind: .series, remoteID: "401"))
        #expect(series.allEpisodes.map(\.key.remoteID) == ["501", "502", "503"])
        #expect(try await URLSessionTransport().get(try client.episodeStreamURL(series.allEpisodes[0]), maxBytes: 8 << 20).statusCode == 200)
    }
}

@Suite(.serialized) struct ShowcaseCatalogIntegrationTests {
    /// The sample experience's fictional catalogue decodes cleanly through the real client.
    @Test func showcaseCatalogueIsCompleteAndPlayable() async throws {
        let server = try FixtureServer(port: 0, catalog: .showcase)
        try await server.start()
        defer { server.stop() }
        let providerID = UUID()
        let client = XtreamClient(
            providerID: providerID, endpoint: try XtreamEndpoint(baseURL: try #require(server.baseURL)),
            credentials: XtreamCredentials(username: FixtureServer.username, password: FixtureServer.password),
            transport: URLSessionTransport(), retryPolicy: .none)
        let transport = URLSessionTransport()

        let categories = try await client.liveCategories()
        let channels = try await client.liveStreams()
        #expect(categories.items.count == ShowcaseCatalog.liveCategories.count && categories.droppedCount == 0)
        #expect(channels.items.count == ShowcaseCatalog.channels.count && channels.droppedCount == 0)
        #expect(channels.items.allSatisfy { $0.epgChannelID != nil })

        let channel = try #require(channels.items.first)
        let now = Date()
        let short = try await client.shortEPG(for: channel.key, limit: 4, serverTimeZone: .current)
        #expect(short.programs.count == 4 && short.droppedCount == 0)
        #expect(NowNext(programs: short.programs, at: now).now != nil)
        let day = try await client.fullEPG(for: channel.key, serverTimeZone: .current)
        #expect(day.programs.count > 20)
        let live = try await transport.get(client.liveStreamURL(for: channel, format: .hls), maxBytes: 1 << 20)
        #expect(live.statusCode == 200)

        let movies = try await client.vodStreams()
        #expect(movies.items.count == ShowcaseCatalog.films.count && movies.droppedCount == 0)
        let film = try #require(movies.items.first)
        let poster = try await transport.get(try #require(film.posterURL), maxBytes: 1 << 20)
        #expect(poster.statusCode == 200 && poster.contentType == "image/jpeg")
        let detail = try await client.movieDetail(film.key)
        #expect(detail.backdropURL != nil && detail.containerExtension == "mp4" && detail.plot != nil)
        let movie = try await transport.get(try client.movieStreamURL(film.key, containerExtension: detail.containerExtension), maxBytes: 8 << 20)
        #expect(movie.statusCode == 200 && movie.contentType == "video/mp4")

        let shows = try await client.seriesList()
        #expect(shows.items.count == ShowcaseCatalog.shows.count && shows.droppedCount == 0)
        for show in shows.items {
            let series = try await client.seriesDetail(show.key)
            #expect(!series.allEpisodes.isEmpty && series.allEpisodes.allSatisfy { !$0.title.isEmpty })
        }
        let first = try await client.seriesDetail(try #require(shows.items.first).key)
        let episode = try await transport.get(try client.episodeStreamURL(first.allEpisodes[0]), maxBytes: 8 << 20)
        #expect(episode.statusCode == 200)
    }
}
