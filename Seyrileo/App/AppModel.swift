import Foundation
import Observation
import SeyrileoFixtureServer
import SeyrileoKit

/// App-wide state and dependency container. Holds no secrets itself: credentials are read
/// from the Keychain when a client is created.
@MainActor
@Observable
final class AppModel {
    enum LaunchState: Equatable {
        case launching
        case ready
        case failed(String)
    }

    private(set) var launchState: LaunchState = .launching
    private(set) var sources: [ProviderSource] = []
    private(set) var activeCatalog: SourceCatalogModel?
    private(set) var activeLibrary: LibraryCatalogModel?
    private(set) var fixtureServerError: String?
    /// The full-screen player, presented from the root so it survives list navigation.
    var playerPresentation: PlayerPresentation?
    /// Set while the player is minimized: playback continues in the floating mini player.
    private(set) var miniPresentation: PlayerPresentation?
    @ObservationIgnored private var isMinimizing = false
    /// Set by a swipe-down minimize: the mini player starts Picture in Picture once it can.
    @ObservationIgnored private var pictureInPictureRequested = false

    let playback: PlaybackCoordinator
    let parental: ParentalModel
    let reminders = ReminderCenter()
    let pro = ProStore()

    /// Provider sources (the on-device sample does not count toward the free limit).
    var realSourceCount: Int { sources.filter { !$0.isFixture }.count }
    /// A problem opening something from outside the app (e.g. a reminder), shown at the root.
    var routeIssue: UserIssue?
    @ObservationIgnored let transport: HTTPTransport
    @ObservationIgnored private let credentialStore: CredentialStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var database: AppDatabase?
    @ObservationIgnored private var registry: SourceRegistry?
    @ObservationIgnored private var fixtureServer: FixtureServer?
    @ObservationIgnored private var fixtureStart: Task<Void, Error>?
    @ObservationIgnored private static let activeSourceKey = "activeSourceID"

    init(
        transport: HTTPTransport, credentialStore: CredentialStore, playback: PlaybackCoordinator,
        parental: ParentalModel, defaults: UserDefaults = .standard
    ) {
        self.transport = transport
        self.credentialStore = credentialStore
        self.playback = playback
        self.parental = parental
        self.defaults = defaults
    }

    static func live() -> AppModel {
        #if DEBUG
        // UI tests start without a parental PIN, whatever a previous run left in the Keychain.
        if ProcessInfo.processInfo.arguments.contains("-SeyrileoResetParental") {
            try? KeychainPINStore().saveRecord(nil)
            try? KeychainPINStore().saveAttempts(PINAttemptState())
        }
        #endif
        return AppModel(
            transport: URLSessionTransport(),
            credentialStore: KeychainCredentialStore(),
            playback: PlaybackCoordinator(factories: [AVPlayerEngineFactory(), VLCEngineFactory()]),
            parental: ParentalModel(gate: ParentalGate(store: KeychainPINStore())))
    }

    var activeSource: ProviderSource? { activeCatalog?.source }
    var hasFixtureSource: Bool { sources.contains(where: \.isFixture) }

    // MARK: - Lifecycle

    func launch() async {
        guard launchState == .launching else { return }
        let credentialStore = credentialStore
        do {
            // Opening/migrating the database and importing the Milestone 1 JSON happen off the
            // main actor so the first frame is never blocked.
            let (database, registry, sources) = try await Task.detached(priority: .userInitiated) {
                let database = try AppDatabase.onDisk(at: try AppDatabase.defaultLocation())
                let store = DatabaseSourceStore(database: database)
                if let legacy = try? FileSourceStore.defaultLocation() {
                    try store.importLegacyJSON(at: legacy)
                }
                let registry = SourceRegistry(sourceStore: store, credentialStore: credentialStore)
                try? registry.pruneOrphanedCredentials()
                return (database, registry, try registry.sources())
            }.value
            self.database = database
            self.registry = registry
            self.sources = sources
        } catch {
            launchState = .failed(String(describing: type(of: error)))
            return
        }
        Task { await pro.start() }
        reminders.isLocked = { [weak self] key in await self?.isLockedForNotifications(key) ?? false }
        if let database { await reminders.configure(store: ReminderStore(database: database)) }
        playback.onTracksChosen = { [weak self] item, preference in
            guard let self else { return }
            self.saveTrackPreference(preference, key: self.trackKeys[item.id] ?? item.id)
        }
        playback.onPlaybackStarted = { [weak self] item in
            self?.recordPlayed(item)
        }
        playback.onProgress = { [weak self] item, position, duration in
            guard let library = self?.activeLibrary, library.source.id == item.id.providerID else { return }
            Task { await library.saveProgress(item, position: position, duration: duration) }
        }
        await ensureFixtureServerIfNeeded()
        let storedID = defaults.string(forKey: Self.activeSourceKey).flatMap(UUID.init(uuidString:))
        activate(sources.first { $0.id == storedID } ?? sources.first)
        launchState = .ready
        #if DEBUG
        if ProviderProbe.isRequested, let source = sources.first(where: { !$0.isFixture }), let client = try? makeClient(for: source) {
            Task { await ProviderProbe.run(source: source, client: client) }
        }
        #endif
    }

    /// The loopback listener does not survive suspension reliably; restart it when needed.
    func ensureFixtureServerIfNeeded() async {
        guard hasFixtureSource else { return }
        do {
            try await startFixtureServer()
            fixtureServerError = nil
        } catch {
            fixtureServerError = String(describing: error)
        }
    }

    /// Coalesces concurrent starts (launch and scene activation both ask for the server);
    /// two overlapping starts would race for the fixed port and report "address in use".
    private func startFixtureServer() async throws {
        if let fixtureStart {
            try await fixtureStart.value
            return
        }
        let server = try fixtureServer ?? FixtureServer(port: Self.fixturePort)
        fixtureServer = server
        let task = Task { _ = try await server.start() }
        fixtureStart = task
        defer { fixtureStart = nil }
        try await task.value
    }

    // MARK: - Sources

    func makeClient(for source: ProviderSource) throws -> XtreamClient {
        guard let credentials = try credentialStore.load(for: source.id) else { throw SourceAccessError.missingCredentials }
        return XtreamClient(
            providerID: source.id, endpoint: try XtreamEndpoint(baseURL: source.serverURL), credentials: credentials,
            transport: transport)
    }

    func makeClient(endpoint: XtreamEndpoint, credentials: XtreamCredentials, providerID: UUID) -> XtreamClient {
        XtreamClient(providerID: providerID, endpoint: endpoint, credentials: credentials, transport: transport)
    }

    /// Saves an already-verified source, makes it active and starts its first catalogue download.
    func save(_ source: ProviderSource, credentials: XtreamCredentials) async throws {
        guard let registry else { throw SourceAccessError.missingCredentials }
        sources = try await Task.detached { try registry.add(source, credentials: credentials) }.value
        activate(source)
    }

    func activate(_ source: ProviderSource?) {
        guard source?.id != activeCatalog?.source.id else { return }
        playerPresentation = nil
        miniPresentation = nil
        playback.stop()
        activeCatalog?.cancelRefresh()
        activeLibrary?.cancelRefresh()
        defaults.set(source?.id.uuidString, forKey: Self.activeSourceKey)
        guard let source, let database else {
            activeCatalog = nil
            activeLibrary = nil
            Task { await parental.activate(store: nil, sourceID: nil) }
            return
        }
        let parental = parental
        Task { await parental.activate(store: ParentalStore(database: database), sourceID: source.id) }
        activeLibrary = LibraryCatalogModel(
            source: source, catalog: LibraryCatalogStore(database: database), progress: ProgressStore(database: database)
        ) { [weak self] in
            guard let self else { throw SourceAccessError.missingCredentials }
            return try self.makeClient(for: source)
        }
        let catalog = SourceCatalogModel(
            source: source, catalog: CatalogStore(database: database), library: LibraryStore(database: database),
            organization: OrganizationStore(database: database)
        ) { [weak self] in
            guard let self else { throw SourceAccessError.missingCredentials }
            return try self.makeClient(for: source)
        }
        activeCatalog = catalog
        Task { await catalog.start() }
    }

    func remove(_ source: ProviderSource) async throws {
        guard let registry else { return }
        if activeCatalog?.source.id == source.id { activate(nil) }
        sources = try await Task.detached { try registry.remove(sourceID: source.id) }.value
        if activeCatalog == nil { activate(sources.first) }
        await reminders.reconcile()
        if !hasFixtureSource {
            fixtureServer?.stop()
            fixtureServer = nil
        }
    }

    // MARK: - Player presentation

    func presentPlayer(_ presentation: PlayerPresentation) {
        miniPresentation = nil
        playerPresentation = presentation
    }

    /// Keeps the session and shows it in the mini player while the user browses. With
    /// `startingPictureInPicture` the mini player also starts PiP when the content supports it.
    func minimizePlayer(startingPictureInPicture: Bool = false) {
        guard let presentation = playerPresentation else { return }
        isMinimizing = true
        pictureInPictureRequested = startingPictureInPicture
        miniPresentation = presentation
        playerPresentation = nil
    }

    /// Read once by the mini player when it appears.
    func takePictureInPictureRequest() -> Bool {
        defer { pictureInPictureRequested = false }
        return pictureInPictureRequested
    }

    /// Replaces what previous/next walks through (e.g. a series opened from a single episode),
    /// keeping the same presentation so the player stays on screen.
    func replacePlayerEntries(_ entries: [PlayableEntry]) {
        guard let presentation = playerPresentation else { return }
        playerPresentation = PlayerPresentation(id: presentation.id, entries: entries)
    }

    func expandMiniPlayer() {
        guard let presentation = miniPresentation else { return }
        miniPresentation = nil
        playerPresentation = presentation
    }

    /// Called when the full-screen player is gone; ends the session unless it was minimized.
    func playerDismissed() {
        if isMinimizing {
            isMinimizing = false
            return
        }
        guard playerPresentation == nil, miniPresentation == nil else { return }
        playback.stop()
        AudioSessionController.deactivate()
    }

    func closeMiniPlayer() {
        miniPresentation = nil
        playback.stop()
        AudioSessionController.deactivate()
    }

    func removeAllData() async throws {
        for source in sources { try await remove(source) }
        if let registry { try await Task.detached { try registry.pruneOrphanedCredentials() }.value }
        defaults.removeObject(forKey: Self.activeSourceKey)
    }

    /// Resolves any entry to a playback item (live via the live catalogue, movies and episodes
    /// via the library, which also applies saved progress).
    ///
    /// This is the single gate for parental controls: every route that plays something (lists,
    /// search, Your Space, collections, guide, switching inside the player) comes through here.
    func playbackItem(for entry: PlayableEntry, start: StartPreference) async throws -> PlaybackItem {
        let item = try await gatedPlaybackItem(for: entry, start: start)
        trackKeys[item.id] = entry.trackPreferenceKey
        return item.with(trackPreference: await trackPreference(for: entry))
    }

    // MARK: - Reminders

    /// Locked for notification purposes: a PIN exists and the channel or one of its categories
    /// is locked (in its own source, which may not be the active one).
    private func isLockedForNotifications(_ key: MediaKey) async -> Bool {
        guard parental.gate.isEnabled, let database else { return false }
        let locks = (try? await ParentalStore(database: database).lockSet(sourceID: key.providerID)) ?? LockSet()
        guard !locks.isEmpty else { return false }
        let categories = (try? await CatalogStore(database: database).channel(key))?.categoryIDs ?? []
        return locks.isLocked(key, categoryIDs: categories)
    }

    /// Opens the channel of a tapped reminder: switches to its source if needed, then plays it
    /// through the normal (parental-gated) path.
    func openChannel(_ key: MediaKey) async {
        guard let database else { return }
        guard let source = sources.first(where: { $0.id == key.providerID }) else {
            routeIssue = UserIssue(LibraryLookupError.notInCatalogue)
            return
        }
        if activeSource?.id != source.id { activate(source) }
        guard let channel = try? await CatalogStore(database: database).channel(key) else {
            routeIssue = UserIssue(LibraryLookupError.notInCatalogue)
            return
        }
        do {
            let entry = PlayableEntry.channel(channel)
            let item = try await playbackItem(for: entry, start: .resumeIfPossible)
            AudioSessionController.activateForPlayback()
            playback.play(item)
            presentPlayer(PlayerPresentation(entries: [entry]))
        } catch ParentalLockError.cancelled {
        } catch {
            routeIssue = UserIssue(error)
        }
    }

    // MARK: - Audio and subtitle memory

    private func trackPreference(for entry: PlayableEntry) async -> TrackPreference? {
        guard let catalog = activeCatalog else { return nil }
        let key = entry.trackPreferenceKey
        guard let json = try? await catalog.library.preference(forKey: TrackPreference.storageKey(for: key), sourceID: key.providerID)
        else { return nil }
        return try? JSONDecoder().decode(TrackPreference.self, from: Data(json.utf8))
    }

    /// Remembers what the user picked so "Continue" and the next episode open the same way.
    func saveTrackPreference(_ preference: TrackPreference, for entry: PlayableEntry) {
        saveTrackPreference(preference, key: entry.trackPreferenceKey)
    }

    /// Which title (series/movie/channel) a playing item's track choice belongs to.
    @ObservationIgnored private var trackKeys: [MediaKey: MediaKey] = [:]

    private func saveTrackPreference(_ preference: TrackPreference, key: MediaKey) {
        guard let catalog = activeCatalog,
              let json = try? String(decoding: JSONEncoder().encode(preference), as: UTF8.self)
        else { return }
        Task { try? await catalog.library.setPreference(json, forKey: TrackPreference.storageKey(for: key), sourceID: key.providerID) }
    }

    private func gatedPlaybackItem(for entry: PlayableEntry, start: StartPreference) async throws -> PlaybackItem {
        switch entry {
        case .channel(let channel):
            guard let catalog = activeCatalog else { throw SourceAccessError.missingCredentials }
            try await parental.authorize(isLocked: parental.isLocked(channel))
            return try catalog.playbackItem(for: channel)
        case .movie(let movie):
            guard let library = activeLibrary else { throw SourceAccessError.missingCredentials }
            try await parental.authorize(isLocked: parental.isLocked(movie.key, categoryIDs: movie.categoryIDs))
            return try await library.playbackItem(for: entry, start: start)
        case .episode(let episode, _, _):
            guard let library = activeLibrary else { throw SourceAccessError.missingCredentials }
            let categories = await library.series(episode.seriesKey)?.categoryIDs ?? []
            try await parental.authorize(
                isLocked: parental.isLocked(episode.key, categoryIDs: categories, seriesKey: episode.seriesKey))
            return try await library.playbackItem(for: entry, start: start)
        }
    }

    /// "Recently watched" lists live channels; movies and episodes use progress instead.
    private func recordPlayed(_ item: PlaybackItem) {
        guard item.isLive, let catalog = activeCatalog, catalog.source.id == item.id.providerID else { return }
        Task { await catalog.recordPlayed(item) }
    }

    // MARK: - Fixture

    /// Simulators share the Mac's network stack, so two simulators running the app would fight
    /// over one port. DEBUG builds accept `-SeyrileoFixturePort <n>` (used by UI tests).
    static var fixturePort: UInt16 {
        #if DEBUG
        let override = UserDefaults.standard.integer(forKey: "SeyrileoFixturePort")
        if (1024...65535).contains(override) { return UInt16(override) }
        #endif
        return FixtureServer.defaultPort
    }

    /// Creates the clearly labeled sample source backed by the on-device fixture server.
    /// Goes through the same verify-and-save path as a real source.
    func addFixtureSource() async throws {
        if let existing = sources.first(where: \.isFixture) {
            activate(existing)
            return
        }
        try await startFixtureServer()
        let endpoint = try XtreamEndpoint(serverAddress: "http://localhost:\(Self.fixturePort)")
        let credentials = XtreamCredentials(username: FixtureServer.username, password: FixtureServer.password)
        let source = ProviderSource(name: String(app: "Sample (fixture)"), kind: .fixture, serverURL: endpoint.baseURL)
        _ = try await makeClient(endpoint: endpoint, credentials: credentials, providerID: source.id).authenticate()
        try await save(source, credentials: credentials)
    }
}

enum SourceAccessError: Error, SourceAccessErrorMarker {
    case missingCredentials
}
