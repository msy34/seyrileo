import Foundation
import Observation
import SeyrileoKit

/// The active source's live catalogue, served from the on-device database. The saved
/// catalogue is shown immediately on launch; refreshes run in the background and replace it
/// atomically only when they succeed.
@MainActor
@Observable
final class SourceCatalogModel {
    enum RefreshState: Equatable {
        case idle
        case refreshing
        case failed(UserIssue)
    }

    /// A catalogue older than this is refreshed automatically when the source becomes active.
    static let staleAfter: TimeInterval = 6 * 60 * 60

    let source: ProviderSource
    private(set) var status: CatalogStatus?
    private(set) var categories: [CategorySummary] = []
    private(set) var hasLoadedCache = false
    private(set) var refreshState: RefreshState = .idle
    private(set) var favoriteKeys: Set<MediaKey> = []
    /// Incremented whenever favorites or recents change, so views can reload.
    private(set) var libraryRevision = 0
    /// Incremented after each successful refresh, so channel lists can reload.
    private(set) var catalogRevision = 0
    /// Incremented when aliases, hidden items, personal order or collections change.
    private(set) var organizationRevision = 0

    @ObservationIgnored let catalog: CatalogStore
    @ObservationIgnored let library: LibraryStore
    @ObservationIgnored let organization: OrganizationStore
    @ObservationIgnored private let makeClient: () throws -> XtreamClient
    @ObservationIgnored private var client: XtreamClient?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var epgService: EPGService?
    /// Manual guide correction for providers with wrong times (hours, −12…+12).
    private(set) var epgOffsetHours = 0
    /// Incremented when guide settings change so rows reload now/next.
    private(set) var epgRevision = 0

    init(
        source: ProviderSource, catalog: CatalogStore, library: LibraryStore, organization: OrganizationStore,
        makeClient: @escaping () throws -> XtreamClient
    ) {
        self.source = source
        self.catalog = catalog
        self.library = library
        self.organization = organization
        self.makeClient = makeClient
    }

    var account: AccountInfo? { status?.account }
    var preferredFormat: StreamFormat { account?.preferredLiveFormat ?? .hls }

    func start() async {
        await loadCache()
        let isStale = status?.lastSuccessAt.map { Date().timeIntervalSince($0) > Self.staleAfter } ?? true
        if isStale { refresh() }
    }

    func loadCache() async {
        status = try? await catalog.status(sourceID: source.id)
        categories = (try? await catalog.categories(sourceID: source.id)) ?? []
        favoriteKeys = (try? await library.favoriteKeys(sourceID: source.id)) ?? []
        epgOffsetHours = Int((try? await library.preference(forKey: Self.epgOffsetKey, sourceID: source.id)) ?? "") ?? 0
        hasLoadedCache = true
    }

    /// Starts a background refresh unless one is running.
    func refresh() {
        guard refreshTask == nil else { return }
        refreshState = .refreshing
        refreshTask = Task { [weak self] in
            await self?.performRefresh()
            self?.refreshTask = nil
        }
    }

    /// For pull-to-refresh: waits for the refresh to finish.
    func refreshAndWait() async {
        refresh()
        await refreshTask?.value
    }

    func cancelRefresh() {
        refreshTask?.cancel()
    }

    private func performRefresh() async {
        do {
            let client = try resolvedClient()
            let outcome = try await catalog.refresh(sourceID: source.id) { try await client.fetchLiveSnapshot() }
            await loadCache()
            if case .applied = outcome {
                catalogRevision += 1
                await epgService?.invalidate()
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

    // MARK: - Guide (EPG)

    private static let epgOffsetKey = "epgOffsetHours"

    /// Built on first use with the panel's time zone and the user's offset.
    private func guideService() throws -> EPGService {
        if let epgService { return epgService }
        let client = try resolvedClient()
        let zone = account?.serverTimezone.flatMap(TimeZone.init(identifier:)) ?? .current
        let offset = TimeInterval(epgOffsetHours * 3600)
        let service = EPGService(
            fetchShort: { key in try await client.shortEPG(for: key, limit: 4, serverTimeZone: zone, offset: offset) },
            fetchFull: { key in try await client.fullEPG(for: key, serverTimeZone: zone, offset: offset) })
        epgService = service
        return service
    }

    /// nil when the channel has no guide id or the provider returned nothing.
    func nowNext(for channel: LiveChannel) async -> NowNext? {
        guard channel.epgChannelID != nil, let service = try? guideService() else { return nil }
        return await service.nowNext(for: channel.key)
    }

    func guide(for channel: LiveChannel) async throws -> [EPGProgram] {
        guard channel.epgChannelID != nil else { return [] }
        return try await guideService().guide(for: channel.key)
    }

    func channelsWithGuide() async -> [LiveChannel] {
        (try? await catalog.channelsWithGuide(sourceID: source.id)) ?? []
    }

    func setEPGOffset(hours: Int) async {
        let clamped = min(max(hours, -12), 12)
        try? await library.setPreference(clamped == 0 ? nil : String(clamped), forKey: Self.epgOffsetKey, sourceID: source.id)
        epgOffsetHours = clamped
        epgService = nil
        epgRevision += 1
    }

    // MARK: - Reading

    func channels(inCategory categoryID: String) async -> [LiveChannel] {
        (try? await catalog.channels(sourceID: source.id, categoryID: categoryID)) ?? []
    }

    func makeSearchController(categoryID: String? = nil) -> ChannelSearchController {
        let controller = ChannelSearchController(sourceID: source.id, store: catalog)
        controller.categoryID = categoryID
        return controller
    }

    func favorites() async -> [FavoriteEntry] {
        (try? await library.favorites(sourceID: source.id)) ?? []
    }

    func recents() async -> [RecentEntry] {
        (try? await library.recents(sourceID: source.id)) ?? []
    }

    // MARK: - User data

    func isFavorite(_ key: MediaKey) -> Bool { favoriteKeys.contains(key) }

    func toggleFavorite(_ channel: LiveChannel) async {
        guard let isFavorite = try? await library.toggleFavorite(channel.key, title: Self.title(channel)) else { return }
        if isFavorite { favoriteKeys.insert(channel.key) } else { favoriteKeys.remove(channel.key) }
        libraryRevision += 1
    }

    /// Removes a favorite whose channel the provider no longer lists.
    func removeUnavailableFavorite(_ key: MediaKey, title: String) async {
        if (try? await library.toggleFavorite(key, title: title)) == false { favoriteKeys.remove(key) }
        libraryRevision += 1
    }

    func reorderFavorites(_ keys: [MediaKey]) async {
        try? await library.reorderFavorites(sourceID: source.id, orderedKeys: keys)
        libraryRevision += 1
    }

    func recordPlayed(_ item: PlaybackItem) async {
        try? await library.recordPlayed(item.id, title: item.title)
        libraryRevision += 1
    }

    // MARK: - Playback

    func playbackItem(for channel: LiveChannel) throws -> PlaybackItem {
        let client = try resolvedClient()
        return PlaybackItem(
            id: channel.key,
            title: Self.title(channel),
            sourceName: source.name,
            url: client.liveStreamURL(for: channel, format: preferredFormat),
            isLive: true,
            redactor: client.redactor)
    }

    static func title(_ channel: LiveChannel) -> String {
        channel.displayName.isEmpty ? String(app: "Untitled channel") : channel.displayName
    }

    // MARK: - Personal organization

    private func organizationChanged() async {
        categories = (try? await catalog.categories(sourceID: source.id)) ?? categories
        organizationRevision += 1
        libraryRevision += 1
    }

    /// Runs a change and reports failures as a user-facing issue (nil on success).
    private func change(_ body: () async throws -> Void) async -> UserIssue? {
        do {
            try await body()
            await organizationChanged()
            return nil
        } catch {
            return UserIssue(error)
        }
    }

    func setAlias(_ alias: String?, for channel: LiveChannel) async -> UserIssue? {
        await change { try await organization.setAlias(alias, for: channel.key) }
    }

    func setHidden(_ hidden: Bool, channel: LiveChannel) async {
        _ = await change { try await organization.setHidden(hidden, channel: channel.key) }
    }

    func setHidden(_ hidden: Bool, category: LiveCategory) async {
        _ = await change { try await organization.setHidden(hidden, categoryID: category.remoteID, sourceID: source.id) }
    }

    func setChannelOrder(_ channels: [LiveChannel], in categoryID: String) async {
        _ = await change {
            try await organization.setChannelOrder(sourceID: source.id, categoryID: categoryID, orderedRemoteIDs: channels.map(\.key.remoteID))
        }
    }

    func resetChannelOrder(in categoryID: String) async {
        _ = await change { try await organization.resetChannelOrder(sourceID: source.id, categoryID: categoryID) }
    }

    func hasCustomChannelOrder(in categoryID: String) async -> Bool {
        (try? await organization.hasCustomChannelOrder(sourceID: source.id, categoryID: categoryID)) ?? false
    }

    func setCategoryOrder(_ categories: [CategorySummary]) async {
        self.categories = categories
        _ = await change { try await organization.setCategoryOrder(sourceID: source.id, orderedRemoteIDs: categories.map(\.id)) }
    }

    func resetCategoryOrder() async {
        _ = await change { try await organization.resetCategoryOrder(sourceID: source.id) }
    }

    func hiddenChannels() async -> [LiveChannel] {
        (try? await catalog.hiddenChannels(sourceID: source.id)) ?? []
    }

    func hiddenCategories() async -> [LiveCategory] {
        ((try? await catalog.categories(sourceID: source.id, includeHidden: true)) ?? []).map(\.category).filter(\.isHidden)
    }

    // MARK: Collections

    func collections() async -> [UserCollection] {
        (try? await organization.collections(sourceID: source.id)) ?? []
    }

    func createCollection(named name: String) async throws -> UserCollection {
        let collection = try await organization.createCollection(named: name, sourceID: source.id)
        await organizationChanged()
        return collection
    }

    func renameCollection(_ collection: UserCollection, to name: String) async -> UserIssue? {
        await change { try await organization.renameCollection(collection.id, to: name) }
    }

    func deleteCollection(_ collection: UserCollection) async {
        _ = await change { try await organization.deleteCollection(collection.id) }
    }

    func reorderCollections(_ collections: [UserCollection]) async {
        _ = await change { try await organization.reorderCollections(sourceID: source.id, orderedIDs: collections.map(\.id)) }
    }

    func items(in collection: UserCollection) async -> [CollectionEntry] {
        (try? await organization.items(in: collection.id)) ?? []
    }

    func collectionIDs(containing key: MediaKey) async -> Set<UUID> {
        (try? await organization.collectionIDs(containing: key)) ?? []
    }

    func setMembership(_ isMember: Bool, key: MediaKey, title: String, collection: UserCollection) async {
        _ = await change {
            if isMember {
                try await organization.add(key, title: title, to: collection.id)
            } else {
                try await organization.remove(key, from: collection.id)
            }
        }
    }

    func reorderItems(_ items: [CollectionEntry], in collection: UserCollection) async {
        _ = await change { try await organization.reorderItems(in: collection.id, orderedKeys: items.map(\.key)) }
    }
}
