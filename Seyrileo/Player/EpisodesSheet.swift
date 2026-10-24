import SeyrileoKit
import SwiftUI

/// "Show episodes" inside the player: every episode of the series being watched, opened on the
/// current season. Picking one plays it in the same player (through `AppModel.playbackItem`).
struct EpisodesSheet: View {
    let current: Episode
    let seriesTitle: String
    let seriesPosterURL: URL?
    /// The chosen episode and the whole series (for previous/next).
    let select: (PlayableEntry, [PlayableEntry]) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var detail: SeriesDetail?
    @State private var issue: UserIssue?
    @State private var season: Int?
    @State private var progress: [MediaKey: PlaybackProgress] = [:]

    var body: some View {
        NavigationStack {
            BrandList {
                switch (detail, issue) {
                case (nil, nil):
                    LoadingRow(text: "Loading episodes…")
                case (nil, let issue?):
                    IssueView(issue: issue) { Task { await load() } }
                case (let detail?, _):
                    episodes(detail)
                }
            }
            .navigationTitle(seriesTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .environment(\.colorScheme, .dark)
        .task { await load() }
        .accessibilityIdentifier("player.episodes")
    }

    @ViewBuilder
    private func episodes(_ detail: SeriesDetail) -> some View {
        if detail.seasons.isEmpty {
            ContentUnavailableView("No episodes", systemImage: "tv", description: Text("The provider lists no episodes for this series."))
        } else {
            let selected = detail.seasons.first { $0.number == (season ?? current.seasonNumber) } ?? detail.seasons[0]
            Section {
                if detail.seasons.count > 1 {
                    Picker("Season", selection: Binding(get: { selected.number }, set: { season = $0 })) {
                        ForEach(detail.seasons) { season in
                            Text(season.name ?? String(app: "Season \(season.number)")).tag(season.number)
                        }
                    }
                }
                ForEach(selected.episodes) { episode in
                    let isCurrent = episode.key == current.key
                    Button {
                        dismiss()
                        guard !isCurrent else { return }
                        select(entry(episode), detail.allEpisodes.map(entry))
                    } label: {
                        EpisodeRow(episode: episode, progress: progress[episode.key], isCurrent: isCurrent)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(isCurrent ? Color.accent.opacity(0.2) : Color.brandRow)
                }
            } header: {
                Text("Episodes")
            }
        }
    }

    private func entry(_ episode: Episode) -> PlayableEntry {
        .episode(episode, seriesTitle: seriesTitle, seriesPosterURL: seriesPosterURL)
    }

    private func load() async {
        guard let library = app.activeLibrary else { return }
        issue = nil
        progress = await library.episodeProgress(current.seriesKey)
        do { detail = try await library.seriesDetail(current.seriesKey) } catch { issue = UserIssue(error) }
    }
}
