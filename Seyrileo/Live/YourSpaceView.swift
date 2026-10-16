import SeyrileoKit
import SwiftUI

/// Continue watching (movies, episodes), favorite channels in the user's own order and
/// recently watched channels of the active source.
struct YourSpaceView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationStack {
            Group {
                if let catalog = app.activeCatalog, let library = app.activeLibrary {
                    SpaceList(catalog: catalog, library: library)
                        .id(catalog.source.id)
                } else {
                    ContentUnavailableView(
                        "No source selected", systemImage: "antenna.radiowaves.left.and.right",
                        description: Text("Add or select a source in Settings."))
                }
            }
            .navigationTitle("Your Space")
        }
    }
}

private struct SpaceList: View {
    let catalog: SourceCatalogModel
    let library: LibraryCatalogModel
    @State private var favorites: [FavoriteEntry]?
    @State private var recents: [RecentEntry] = []
    @State private var continueWatching: [PlaybackProgress] = []
    /// Continue-watching entries whose title or categories are locked.
    @State private var lockedProgress: Set<MediaKey> = []
    @Environment(AppModel.self) private var app
    @State private var player = PlayerLauncher()
    @State private var issue: UserIssue?

    private var playableFavorites: [LiveChannel] { (favorites ?? []).compactMap(\.channel) }

    var body: some View {
        List {
            Section {
                BrandGreetingHeader(sourceName: catalog.source.name)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            if !continueWatching.isEmpty {
                Section {
                    ForEach(continueWatching) { progress in
                        Button { Task { await resume(progress) } } label: {
                            if app.parental.isRestricting, lockedProgress.contains(progress.key) {
                                LockedRow(title: "Locked title")
                            } else {
                                ContinueRow(progress: progress)
                            }
                        }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button("Remove", systemImage: "xmark", role: .destructive) {
                                    Task { await library.removeFromContinueWatching(progress.key) }
                                }
                            }
                    }
                } header: {
                    Text("Continue watching")
                }
            }

            Section {
                if let favorites {
                    if favorites.isEmpty {
                        Text("Swipe left on a channel, or touch and hold it, to add it to your favorites.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(favorites) { entry in
                        SpaceRow(title: entry.title, channel: entry.channel, isFavorite: true, catalog: catalog, list: playableFavorites, player: player)
                            .swipeActions {
                                Button("Remove from favorites", systemImage: "star.slash", role: .destructive) {
                                    Task { await removeFavorite(entry) }
                                }
                            }
                    }
                    .onMove { from, to in move(from: from, to: to) }
                } else {
                    LoadingRow(text: "Loading…")
                }
            } header: {
                Text("Favorites")
            }

            CollectionsSection(catalog: catalog)

            Section {
                if recents.isEmpty {
                    Text("Channels you watch will appear here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(recents) { entry in
                    SpaceRow(
                        title: entry.title, channel: entry.channel, isFavorite: catalog.isFavorite(entry.key), catalog: catalog,
                        list: recents.compactMap(\.channel), player: player)
                }
            } header: {
                Text("Recently watched")
            }
        }
        .toolbar {
            if !(favorites ?? []).isEmpty { EditButton() }
        }
        .navigationDestination(for: UserCollection.self) { collection in
            CollectionDetailView(collection: collection, catalog: catalog, library: library)
        }
        .libraryDestinations(library: library, catalog: catalog)
        .task(id: [catalog.libraryRevision, catalog.catalogRevision]) {
            favorites = await catalog.favorites()
            recents = await catalog.recents()
        }
        .task(id: library.progressRevision) {
            continueWatching = await library.continueWatching()
        }
        .task(id: [library.progressRevision, app.parental.revision]) {
            var locked: Set<MediaKey> = []
            for progress in await library.continueWatching() {
                let categories: [String]
                if let seriesKey = progress.seriesKey {
                    categories = await library.series(seriesKey)?.categoryIDs ?? []
                } else {
                    categories = await library.movie(progress.key)?.categoryIDs ?? []
                }
                if app.parental.isLocked(progress.key, categoryIDs: categories, seriesKey: progress.seriesKey) {
                    locked.insert(progress.key)
                }
            }
            lockedProgress = locked
        }
        .alert(
            issue.map { Text($0.title) } ?? Text(verbatim: ""),
            isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } }),
            presenting: issue
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { issue in
            Text(issue.detail)
        }
        .playerPresentation(player, catalog: catalog)
    }

    private func resume(_ progress: PlaybackProgress) async {
        do {
            let (entry, list) = try await library.entries(forContinuing: progress)
            await player.play(entry, in: list, start: .resumeIfPossible)
        } catch {
            issue = UserIssue(error)
        }
    }

    private func move(from: IndexSet, to: Int) {
        guard var list = favorites else { return }
        list.move(fromOffsets: from, toOffset: to)
        favorites = list
        Task { await catalog.reorderFavorites(list.map(\.key)) }
    }

    private func removeFavorite(_ entry: FavoriteEntry) async {
        if let channel = entry.channel {
            await catalog.toggleFavorite(channel)
        } else {
            await catalog.removeUnavailableFavorite(entry.key, title: entry.title)
        }
    }
}

private struct ContinueRow: View {
    let progress: PlaybackProgress

    var body: some View {
        HStack(spacing: 12) {
            PosterImage(url: progress.posterURL, title: progress.seriesTitle ?? progress.title, width: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(progress.seriesTitle ?? progress.title).lineLimit(1)
                if progress.seriesTitle != nil {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let fraction = progress.fraction { ProgressLine(fraction: fraction) }
                if let duration = progress.duration {
                    Text("\(DurationText.format(max(0, duration - progress.position))) left")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "play.fill").foregroundStyle(.tint).accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let season = progress.seasonNumber {
            parts.append(progress.episodeNumber.map { String(localized: "S\(season) E\($0)") } ?? String(localized: "Season \(season)"))
        }
        parts.append(progress.title)
        return parts.joined(separator: " · ")
    }
}

private struct SpaceRow: View {
    let title: String
    let channel: LiveChannel?
    let isFavorite: Bool
    let catalog: SourceCatalogModel
    let list: [LiveChannel]
    let player: PlayerLauncher

    var body: some View {
        if let channel {
            Button { player.play(channel, in: list, catalog: catalog) } label: {
                ChannelRow(channel: channel, isFavorite: isFavorite)
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 12) {
                Monogram(text: title)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.secondary)
                    Text("No longer offered by this source").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }
}
