import SeyrileoKit
import SwiftUI

struct MovieDetailView: View {
    let library: LibraryCatalogModel
    let catalog: SourceCatalogModel
    let movie: Movie
    @State private var detail: MovieDetail?
    @State private var detailIssue: UserIssue?
    @State private var progress: PlaybackProgress?
    @State private var player = PlayerLauncher()
    @State private var collecting: CollectableItem?

    @Environment(AppModel.self) private var app

    var body: some View {
        ParentalGuard(isLocked: app.parental.isLocked(movie.key, categoryIDs: movie.categoryIDs)) {
            page
        }
    }

    private var page: some View {
        BrandList {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    PosterImage(url: detail?.posterURL ?? movie.posterURL, title: movie.name, width: 110)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(detail?.name ?? movie.name).font(.title3.weight(.semibold))
                        facts
                    }
                }
                .listRowBackground(Color.clear)
            }
            Section { playButtons }
            if let plot = detail?.plot {
                Section("Plot") { Text(plot).font(.body) }
            }
            if detail?.cast != nil || detail?.director != nil || detail?.country != nil {
                Section("Details") {
                    if let director = detail?.director { LabeledContent("Director", value: director) }
                    if let cast = detail?.cast { LabeledContent("Cast") { Text(cast).multilineTextAlignment(.trailing) } }
                    if let country = detail?.country { LabeledContent("Country", value: country) }
                }
            }
            if let detailIssue {
                Section {
                    Text("Details couldn't be loaded: \(Text(app: detailIssue.title)). You can still try to play it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(movie.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { detail = try await library.movieDetail(movie.key) } catch { detailIssue = UserIssue(error) }
        }
        .task(id: library.progressRevision) { progress = await library.progress(movie.key) }
        .toolbar {
            Button {
                collecting = CollectableItem(key: movie.key, title: movie.name)
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
    private var facts: some View {
        let items: [String] = [
            detail?.releaseDate.map { String($0.prefix(4)) },
            detail?.durationSeconds.map { DurationText.format(TimeInterval($0)) },
            detail?.genre,
            (detail?.rating ?? movie.rating).map { "★ \($0)" },
            (movie.containerExtension ?? detail?.containerExtension)?.uppercased(),
        ].compactMap { $0 }
        if !items.isEmpty {
            Text(items.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var playButtons: some View {
        if let progress, progress.isResumable {
            Button {
                Task { await player.play(.movie(movie), in: [.movie(movie)], start: .resumeIfPossible) }
            } label: {
                Label("Resume from \(DurationText.clock(progress.position))", systemImage: "play.fill")
            }
            if let fraction = progress.fraction { ProgressLine(fraction: fraction) }
            Button {
                Task { await player.play(.movie(movie), in: [.movie(movie)], start: .beginning) }
            } label: {
                Label("Play from the beginning", systemImage: "arrow.counterclockwise")
            }
        } else {
            Button {
                Task { await player.play(.movie(movie), in: [.movie(movie)], start: .beginning) }
            } label: {
                Label(progress?.completed == true ? "Play again" : "Play", systemImage: "play.fill")
            }
        }
    }
}
