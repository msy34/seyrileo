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
    @State private var creatingCollection = false
    @Environment(AppModel.self) private var app
    @State private var player = PlayerLauncher()
    @State private var issue: UserIssue?
    /// Sections the user expanded beyond the first `SectionPreview.limit` entries.
    @State private var expanded: Set<String> = []
    @Environment(\.editMode) private var editMode

    private var playableFavorites: [LiveChannel] { (favorites ?? []).compactMap(\.channel) }

    var body: some View {
        BrandList {
            Section {
                BrandGreetingHeader(sourceName: catalog.source.name)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            if !continueWatching.isEmpty {
                Section {
                    ForEach(shown(continueWatching, "continue")) { progress in
                        let isLocked = app.parental.isRestricting && lockedProgress.contains(progress.key)
                        let isHero = !isLocked && progress.id == continueWatching.first?.id
                        Button { Task { await resume(progress) } } label: {
                            if isLocked {
                                LockedRow(title: "Locked title")
                            } else if isHero {
                                ContinueHero(progress: progress)
                            } else {
                                ContinueRow(progress: progress)
                            }
                        }
                            .listRowInsets(isHero ? EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0) : nil)
                            .listRowBackground(isHero ? Color.clear : Color.brandRow)
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button("Remove", systemImage: "xmark", role: .destructive) {
                                    Task { await library.removeFromContinueWatching(progress.key) }
                                }
                            }
                    }
                    SectionPreview.Toggle(total: continueWatching.count, id: "continue", expanded: $expanded)
                } header: {
                    Text("Continue watching")
                }
            }

            Section {
                if let favorites {
                    if favorites.isEmpty {
                        CatEmptyState(text: "Swipe left on a channel, or touch and hold it, to add it to your favorites.")
                    }
                    // Reordering needs every favorite on screen.
                    ForEach(editMode?.wrappedValue.isEditing == true ? favorites[...] : shown(favorites, "favorites")) { entry in
                        SpaceRow(title: entry.title, channel: entry.channel, isFavorite: true, catalog: catalog, list: playableFavorites, player: player)
                            .swipeActions {
                                Button("Remove from favorites", systemImage: "star.slash", role: .destructive) {
                                    Task { await removeFavorite(entry) }
                                }
                            }
                    }
                    .onMove { from, to in move(from: from, to: to) }
                    if editMode?.wrappedValue.isEditing != true {
                        SectionPreview.Toggle(total: favorites.count, id: "favorites", expanded: $expanded)
                    }
                } else {
                    LoadingRow(text: "Loading…")
                }
            } header: {
                Text("Favorites")
            }

            CollectionsSection(catalog: catalog, creating: $creatingCollection)

            Section {
                if recents.isEmpty {
                    Text("Channels you watch will appear here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(shown(recents, "recents")) { entry in
                    SpaceRow(
                        title: entry.title, channel: entry.channel, isFavorite: catalog.isFavorite(entry.key), catalog: catalog,
                        list: recents.compactMap(\.channel), player: player)
                }
                SectionPreview.Toggle(total: recents.count, id: "recents", expanded: $expanded)
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
            issue.map { Text(app: $0.title) } ?? Text(verbatim: ""),
            isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } }),
            presenting: issue
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { issue in
            Text(app: issue.detail)
        }
        .newCollectionSheet(isPresented: $creatingCollection, catalog: catalog)
        .playerPresentation(player, catalog: catalog)
    }

    private func shown<Element>(_ list: [Element], _ id: String) -> ArraySlice<Element> {
        expanded.contains(id) ? list[...] : list.prefix(SectionPreview.limit)
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

/// Your Space shows the first few entries of each section; the rest opens on request.
enum SectionPreview {
    static let limit = 5

    /// "Show all (n)" / "Show less" under a section; nothing when everything already fits.
    struct Toggle: View {
        let total: Int
        let id: String
        @Binding var expanded: Set<String>

        var body: some View {
            if total > SectionPreview.limit {
                let isOpen = expanded.contains(id)
                Button {
                    withAnimation(.snappy) {
                        if isOpen { expanded.remove(id) } else { expanded.insert(id) }
                    }
                } label: {
                    HStack {
                        Text(isOpen ? "Show less" : "Show all (\(total))")
                        Spacer()
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(isOpen ? 180 : 0))
                            .accessibilityHidden(true)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accent)
                }
            }
        }
    }
}

/// The newest "continue watching" entry as a large card in the style of the icon's glowing
/// teal play button.
private struct ContinueHero: View {
    let progress: PlaybackProgress

    var body: some View {
        Group {
            HStack(alignment: .bottom, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(progress.seriesTitle ?? progress.title)
                        .font(.system(.title3, design: .rounded).weight(.heavy))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if !ContinueRow.subtitle(for: progress).isEmpty, progress.seriesTitle != nil {
                        Text(ContinueRow.subtitle(for: progress))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.brandCream.opacity(0.9))
                            .lineLimit(1)
                    }
                    if let duration = progress.duration {
                        Text("\(DurationText.format(max(0, duration - progress.position))) left")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    if let fraction = progress.fraction {
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.25))
                                Capsule().fill(Color.brandCream).frame(width: proxy.size.width * fraction)
                            }
                        }
                        .frame(height: 4)
                        .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "play.fill")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color.brandNavy)
                    .frame(width: 48, height: 48)
                    .background(Color.brandCream, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(red: 0.11, green: 0.78, blue: 0.80), Color(red: 0.04, green: 0.56, blue: 0.60), .brandGlow],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(.white.opacity(0.2), lineWidth: 1)
                    }
                    .shadow(color: Color.accent.opacity(0.45), radius: 16, y: 8)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct ContinueRow: View {
    let progress: PlaybackProgress

    static func subtitle(for progress: PlaybackProgress) -> String {
        var parts: [String] = []
        if let season = progress.seasonNumber {
            parts.append(progress.episodeNumber.map { String(app: "S\(season) E\($0)") } ?? String(app: "Season \(season)"))
        }
        parts.append(progress.title)
        return parts.joined(separator: " · ")
    }

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

    private var subtitle: String { Self.subtitle(for: progress) }
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
