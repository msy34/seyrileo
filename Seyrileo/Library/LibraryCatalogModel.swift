import Foundation
import Observation
import SeyrileoKit

/// Movies and series of the active source. Like the live catalogue, the saved library is
/// shown immediately and refreshed in the background (all movies and all series: two list
/// requests plus two category requests). Details are fetched only when a title is opened.
@MainActor
@Observable
final class LibraryCatalogModel {
    static let staleAfter: TimeInterval = 12 * 60 * 60

    let source: ProviderSource
    private(set) var status: LibraryStatus?
    private(set) var movieCategories: [MediaCategorySummary] = []
    private(set) var seriesCategories: [MediaCategorySummary] = []
    private(set) var hasLoadedCache = false
    private(set) var refreshState: SourceCatalogModel.RefreshState = .idle
    private(set) var catalogRevision = 0
    /// Incremented when saved progress changes (continue watching, resume buttons).
    private(set) var progressRevision = 0

    @ObservationIgnored let catalog: LibraryCatalogStore
    @ObservationIgnored let progressStore: ProgressStore
    @ObservationIgnored private let makeClient: () throws -> XtreamClient
    @ObservationIgnored private var client: XtreamClient?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var movieDetails: [MediaKey: MovieDetail] = [:]
    @ObservationIgnored private var seriesDetails: [MediaKey: SeriesDetail] = [:]
    /// Metadata stored with progress for items opened in this session.
    @ObservationIgnored private var progressContext: [MediaKey: PlaybackProgress] = [:]

    init(source: ProviderSource, catalog: LibraryCatalogStore, progress: ProgressStore, makeClient: @escaping () throws -> XtreamClient) {
        self.source = source
        self.catalog = catalog
        self.progressStore = progress
        self.makeClient = makeClient
    }

    // MARK: - Catalogue

    /// Loads the saved library and refreshes it when stale. Called when the Library or a
    /// movie/series search is first used, not at app launch.
    func start() async {
        guard !started else { return }
        started = true
        await loadCache()
        let stale = status?.lastSuccessAt.map { Date().timeIntervalSince($0) > Self.staleAfter } ?? true
        if stale { refresh() }
    }

    func loadCache() async {
        status = try? await catalog.status(sourceID: source.id)
        movieCategories = (try? await catalog.categories(sourceID: source.id, kind: .movie)) ?? []
        seriesCategories = (try? await catalog.categories(sourceID: source.id, kind: .series)) ?? []
        hasLoadedCache = true
    }

    func refresh() {
        guard refreshTask == nil else { return }
        refreshState = .refreshing
        refreshTask = Task { [weak self] in
            await self?.performRefresh()
            self?.refreshTask = nil
        }
    }

    func refreshAndWait() async {
        refresh()
        await refreshTask?.value
    }

    func cancelRefresh() { refreshTask?.cancel() }

    private func performRefresh() async {
        do {
            let client = try resolvedClient()
            let outcome = try await catalog.refresh(sourceID: source.id) { try await client.fetchLibrarySnapshot() }
            await loadCache()
            if case .applied = outcome {
                movieDetails.removeAll()
                seriesDetails.removeAll()
                catalogRevision += 1
            }
            refreshState = .idle
        } catch {
            status = try? await catalog.status(sourceID: source.id)
            refreshState = .failed(UserIssue(error))
        }
    }

    private func resolvedClient() throws -> XtreamClient {
        if let client { return client }
        let client = try makeClient()
        self.client = client
        return client
    }

    func categories(_ kind: MediaKind) -> [MediaCategorySummary] {
        kind == .series ? seriesCategories : movieCategories
    }

    func items(kind: MediaKind, categoryID: String) async -> [SeyrileoKit.LibraryItem] {
        (try? await catalog.items(sourceID: source.id, kind: kind, categoryID: categoryID)) ?? []
    }

    func search(kind: MediaKind, query: String, categoryID: String?) async -> (items: [SeyrileoKit.LibraryItem], isTruncated: Bool)? {
        try? await catalog.search(sourceID: source.id, kind: kind, query: query, categoryID: categoryID)
    }

    // MARK: - Details

    func movieDetail(_ key: MediaKey) async throws -> MovieDetail {
        if let cached = movieDetails[key] { return cached }
        let detail = try await resolvedClient().movieDetail(key)
        movieDetails[key] = detail
        return detail
    }

    func seriesDetail(_ key: MediaKey) async throws -> SeriesDetail {
        if let cached = seriesDetails[key] { return cached }
        let detail = try await resolvedClient().seriesDetail(key)
        seriesDetails[key] = detail
        return detail
    }

    func series(_ key: MediaKey) async -> Series? { try? await catalog.series(key) }
    func movie(_ key: MediaKey) async -> Movie? { try? await catalog.movie(key) }

    // MARK: - Progress

    func progress(_ key: MediaKey) async -> PlaybackProgress? { try? await progressStore.progress(key) }

    func episodeProgress(_ seriesKey: MediaKey) async -> [MediaKey: PlaybackProgress] {
        (try? await progressStore.episodeProgress(seriesKey: seriesKey)) ?? [:]
    }

    func continueWatching() async -> [PlaybackProgress] {
        (try? await progressStore.continueWatching(sourceID: source.id)) ?? []
    }

    func removeFromContinueWatching(_ key: MediaKey) async {
        try? await progressStore.remove(key)
        progressRevision += 1
    }

    /// Saves a position reported by the player for an item opened through this model.
    func saveProgress(_ item: PlaybackItem, position: TimeInterval, duration: TimeInterval?) async {
        guard let context = progressContext[item.id] else { return }
        let progress = PlaybackProgress(
            key: item.id, title: context.title, seriesKey: context.seriesKey, seriesTitle: context.seriesTitle,
            seasonNumber: context.seasonNumber, episodeNumber: context.episodeNumber,
            containerExtension: context.containerExtension, posterURL: context.posterURL, position: position,
            duration: duration ?? context.duration)
        try? await progressStore.save(progress)
        progressRevision += 1
    }

    // MARK: - Playback

    /// Builds the credential-bearing item. The container comes from the list or, if missing
    /// there, from the detail endpoint; it is never guessed.
    func playbackItem(for entry: PlayableEntry, start: StartPreference) async throws -> PlaybackItem {
        let client = try resolvedClient()
        let url: URL
        let context: PlaybackProgress
        switch entry {
        case .channel:
            preconditionFailure("Live channels are resolved by SourceCatalogModel")
        case .movie(let movie):
            var container = movie.containerExtension
            var duration: TimeInterval?
            if let detail = try? await movieDetail(movie.key) {
                container = container ?? detail.containerExtension
                duration = detail.durationSeconds.map(TimeInterval.init)
            }
            url = try client.movieStreamURL(movie.key, containerExtension: container)
            context = PlaybackProgress(
                key: movie.key, title: entry.title, containerExtension: container, posterURL: movie.posterURL,
                position: 0, duration: duration)
        case .episode(let episode, let seriesTitle, let poster):
            url = try client.episodeStreamURL(episode)
            context = PlaybackProgress(
                key: episode.key, title: episode.title.isEmpty ? PlayableEntry.episodeLabel(episode) : episode.title,
                seriesKey: episode.seriesKey, seriesTitle: seriesTitle, seasonNumber: episode.seasonNumber,
                episodeNumber: episode.episodeNumber, containerExtension: episode.containerExtension,
                posterURL: episode.stillURL ?? poster, position: 0, duration: episode.durationSeconds.map(TimeInterval.init))
        }
        // A missing file is often answered with an empty page; say so instead of letting both
        // players fail with a misleading format error.
        if await MediaPreflight().check(url) == .notMedia { throw LibraryPlaybackError.providerReturnedNoMedia }
        progressContext[entry.key] = context
        let startPosition = start == .beginning ? 0 : ProgressPolicy.startPosition(for: await progress(entry.key))
        return PlaybackItem(
            id: entry.key, title: entry.title, sourceName: source.name, url: url, isLive: false,
            redactor: client.redactor, startPosition: startPosition,
            prefersAlternateEngine: Self.needsAlternateEngine(context.containerExtension))
    }

    /// Containers AVFoundation does not open; these start directly in VLC instead of failing
    /// in AVPlayer first.
    static func needsAlternateEngine(_ container: String?) -> Bool {
        ["mkv", "avi", "wmv", "flv", "webm", "mpg", "mpeg", "ts", "divx", "xvid", "ogv", "3gp"].contains(container?.lowercased() ?? "")
    }

    /// Rebuilds an entry from saved progress (Continue watching), loading the series so the
    /// player can offer previous/next episodes.
    func entries(forContinuing progress: PlaybackProgress) async throws -> (entry: PlayableEntry, list: [PlayableEntry]) {
        if progress.key.kind == .episode, let seriesKey = progress.seriesKey {
            let detail = try await seriesDetail(seriesKey)
            let stored = await series(seriesKey)
            let title = stored?.name ?? detail.name ?? progress.seriesTitle ?? ""
            let poster = stored?.posterURL ?? detail.posterURL
            let list = detail.allEpisodes.map { PlayableEntry.episode($0, seriesTitle: title, seriesPosterURL: poster) }
            guard let entry = list.first(where: { $0.key == progress.key }) else { throw LibraryLookupError.notInCatalogue }
            return (entry, list)
        }
        guard let movie = await movie(progress.key) else { throw LibraryLookupError.notInCatalogue }
        return (.movie(movie), [.movie(movie)])
    }
}

/// The saved title is no longer offered by the provider.
enum LibraryLookupError: Error {
    case notInCatalogue
}
