import SeyrileoKit
import SwiftUI

struct SeriesDetailView: View {
    let library: LibraryCatalogModel
    let catalog: SourceCatalogModel
    let series: Series
    @State private var detail: SeriesDetail?
    @State private var issue: UserIssue?
    @State private var progress: [MediaKey: PlaybackProgress] = [:]
    @State private var season: Int?
    @State private var player = PlayerLauncher()
    @State private var collecting: CollectableItem?

    private var entries: [PlayableEntry] {
        (detail?.allEpisodes ?? []).map { .episode($0, seriesTitle: series.name, seriesPosterURL: series.posterURL) }
    }

    /// The most recently watched unfinished episode, else the one after the last finished one.
    private var continueEntry: (entry: PlayableEntry, progress: PlaybackProgress?)? {
        guard let detail else { return nil }
        let watched = progress.values.sorted { $0.updatedAt > $1.updatedAt }
        guard let latest = watched.first else { return nil }
        if latest.isResumable, let entry = entries.first(where: { $0.key == latest.key }) { return (entry, latest) }
        if latest.completed, let next = detail.episode(after: latest.key) {
            return (.episode(next, seriesTitle: series.name, seriesPosterURL: series.posterURL), progress[next.key])
        }
        return nil
    }

    @Environment(AppModel.self) private var app

    var body: some View {
        ParentalGuard(isLocked: app.parental.isLocked(series.key, categoryIDs: series.categoryIDs)) {
            page
        }
    }

    private var page: some View {
        BrandList {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    PosterImage(url: detail?.posterURL ?? series.posterURL, title: series.name, width: 110)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(detail?.name ?? series.name).font(.title3.weight(.semibold))
                        let facts = [detail?.releaseDate ?? series.releaseDate, detail?.genre ?? series.genre,
                                     (detail?.rating ?? series.rating).map { "★ \($0)" }].compactMap { $0 }
                        if !facts.isEmpty { Text(facts.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary) }
                    }
                }
                .listRowBackground(Color.clear)
                if let continueEntry {
                    Button {
                        Task { await player.play(continueEntry.entry, in: entries) }
                    } label: {
                        Label(
                            continueEntry.progress?.isResumable == true
                                ? "Continue \(Self.label(continueEntry.entry))" : "Play \(Self.label(continueEntry.entry))",
                            systemImage: "play.fill")
                    }
                }
            }
            if let plot = detail?.plot ?? series.plot {
                Section("Plot") { Text(plot) }
            }
            switch (detail, issue) {
            case (nil, nil):
                LoadingRow(text: "Loading episodes…")
            case (nil, let issue?):
                IssueView(issue: issue) { Task { await load() } }
            case (let detail?, _):
                episodesSection(detail)
            }
        }
        .navigationTitle(series.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .task(id: library.progressRevision) { progress = await library.episodeProgress(series.key) }
        .toolbar {
            Button {
                collecting = CollectableItem(key: series.key, title: series.name)
            } label: {
                Label("Add to collection", systemImage: "rectangle.stack.badge.plus")
            }
        }
        .sheet(item: $collecting) { item in
            AddToCollectionView(item: item, catalog: catalog)
        }
        .playerPresentation(player, catalog: catalog)
    }

    @ViewBuilder
    private func episodesSection(_ detail: SeriesDetail) -> some View {
        if detail.seasons.isEmpty {
            ContentUnavailableView("No episodes", systemImage: "tv", description: Text("The provider lists no episodes for this series."))
        } else {
            let selected = detail.seasons.first { $0.number == season } ?? detail.seasons[0]
            Section {
                if detail.seasons.count > 1 {
                    Picker("Season", selection: Binding(get: { selected.number }, set: { season = $0 })) {
                        ForEach(detail.seasons) { season in
                            Text(season.name ?? String(app: "Season \(season.number)")).tag(season.number)
                        }
                    }
                }
                ForEach(selected.episodes) { episode in
                    let entry = PlayableEntry.episode(episode, seriesTitle: series.name, seriesPosterURL: series.posterURL)
                    Button {
                        Task { await player.play(entry, in: entries) }
                    } label: {
                        EpisodeRow(episode: episode, progress: progress[episode.key])
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Episodes")
            } footer: {
                if detail.droppedEpisodes > 0 {
                    Text("\(detail.droppedEpisodes) entries from the provider could not be read and were skipped.")
                }
            }
        }
    }

    private func load() async {
        issue = nil
        do { detail = try await library.seriesDetail(series.key) } catch { issue = UserIssue(error) }
    }

    static func label(_ entry: PlayableEntry) -> String {
        if case .episode(let episode, _, _) = entry { return PlayableEntry.episodeLabel(episode) }
        return entry.title
    }
}

struct EpisodeRow: View {
    let episode: Episode
    let progress: PlaybackProgress?
    /// The episode open in the player (episode list inside the player).
    var isCurrent = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(PlayableEntry.episodeLabel(episode)).font(.caption.weight(.semibold)).foregroundStyle(.tint)
                    if progress?.completed == true {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel(Text("Watched"))
                    }
                }
                Text(episode.title.isEmpty ? PlayableEntry.episodeLabel(episode) : episode.title).lineLimit(2)
                if let duration = episode.durationSeconds {
                    Text(DurationText.format(TimeInterval(duration))).font(.caption).foregroundStyle(.secondary)
                }
                if let progress, !progress.completed, let fraction = progress.fraction, progress.isResumable {
                    ProgressLine(fraction: fraction).padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            if isCurrent {
                Label("Now playing", systemImage: "speaker.wave.2.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(Color.brandAmber)
            } else {
                Image(systemName: "play.fill").foregroundStyle(.tint).accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
