import SeyrileoKit
import SwiftUI

/// Movies and series of the active source.
struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @State private var kind: MediaKind = .movie

    var body: some View {
        NavigationStack {
            Group {
                if let library = app.activeLibrary, let catalog = app.activeCatalog {
                    LibraryCategories(library: library, catalog: catalog, kind: $kind)
                } else {
                    ContentUnavailableView(
                        "No source selected", systemImage: "antenna.radiowaves.left.and.right",
                        description: Text("Add or select a source in Settings."))
                }
            }
            .navigationTitle("Library")
        }
        .id(app.activeLibrary?.source.id)
    }
}

private struct LibraryCategories: View {
    let library: LibraryCatalogModel
    let catalog: SourceCatalogModel
    @Binding var kind: MediaKind
    @Environment(AppModel.self) private var app

    var body: some View {
        List {
            Section {
                Picker("Type", selection: $kind) {
                    Text("Movies").tag(MediaKind.movie)
                    Text("Series").tag(MediaKind.series)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            LibraryStatusSection(library: library)
            if library.hasLoadedCache, library.status?.hasCatalog == true {
                let categories = library.categories(kind)
                if categories.isEmpty {
                    ContentUnavailableView(
                        kind == .movie ? "No movie categories" : "No series categories", systemImage: "film.stack",
                        description: Text("This source doesn't list any here."))
                } else {
                    Section {
                        ForEach(categories) { summary in
                            let locked = app.parental.isLocked(categoryID: summary.id, kind: kind)
                            NavigationLink(value: LibraryRoute.category(summary.category)) {
                                LabeledContent {
                                    Text(summary.itemCount, format: .number)
                                } label: {
                                    CategoryTitle(name: summary.category.name, isLocked: locked, isMasked: locked && app.parental.isRestricting)
                                }
                            }
                            .swipeActions {
                                if app.parental.gate.isEnabled, let scope = LockScope.category(for: kind) {
                                    Button(locked ? "Remove lock" : "Lock", systemImage: locked ? "lock.open" : "lock") {
                                        Task { await app.parental.setLocked(!locked, scope: scope, remoteID: summary.id) }
                                    }
                                    .tint(.indigo)
                                }
                            }
                        }
                    } footer: {
                        DroppedFooter(count: library.status?.droppedCount ?? 0)
                    }
                }
            }
        }
        .libraryDestinations(library: library, catalog: catalog)
        .refreshable { await library.refreshAndWait() }
        .task { await library.start() }
    }
}

enum LibraryRoute: Hashable {
    case category(MediaCategory)
    case movie(Movie)
    case series(Series)
}

extension View {
    func libraryDestinations(library: LibraryCatalogModel, catalog: SourceCatalogModel) -> some View {
        navigationDestination(for: LibraryRoute.self) { route in
            switch route {
            case .category(let category):
                LibraryItemsView(library: library, catalog: catalog, category: category)
            case .movie(let movie):
                MovieDetailView(library: library, catalog: catalog, movie: movie)
            case .series(let series):
                SeriesDetailView(library: library, catalog: catalog, series: series)
            }
        }
    }
}

struct LibraryStatusSection: View {
    let library: LibraryCatalogModel

    var body: some View {
        let hasCatalog = library.status?.hasCatalog == true
        switch library.refreshState {
        case .refreshing:
            if hasCatalog {
                Section { Label { Text("Updating library…") } icon: { PawLoader(size: 12) }.font(.footnote) }
            } else {
                LoadingRow(text: "Downloading movies and series…")
            }
        case .failed(let issue):
            if hasCatalog {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Couldn't update. Showing the saved library.", systemImage: "exclamationmark.arrow.circlepath")
                            .font(.footnote.weight(.semibold))
                        Text(issue.title).font(.footnote).foregroundStyle(.secondary)
                        Button("Try again") { library.refresh() }.font(.footnote)
                    }
                }
            } else {
                IssueView(issue: issue) { library.refresh() }
            }
        case .idle:
            if !library.hasLoadedCache {
                LoadingRow(text: "Loading…")
            } else if let status = library.status, let date = status.lastSuccessAt {
                Section {
                    Text("\(status.movieCount) movies · \(status.seriesCount) series · updated \(date, format: .relative(presentation: .named))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct LibraryItemsView: View {
    let library: LibraryCatalogModel
    let catalog: SourceCatalogModel
    let category: MediaCategory
    @State private var items: [SeyrileoKit.LibraryItem]?
    @State private var query = ""
    @State private var results: [SeyrileoKit.LibraryItem]?
    @State private var collecting: CollectableItem?
    @Environment(AppModel.self) private var app

    var body: some View {
        ParentalGuard(isLocked: app.parental.isLocked(categoryID: category.remoteID, kind: category.kind)) {
            itemList
        }
    }

    private var itemList: some View {
        List {
            let shown = query.trimmingCharacters(in: .whitespaces).isEmpty ? items : results
            switch shown {
            case nil:
                LoadingRow(text: "Loading…")
            case let list? where list.isEmpty:
                if query.isEmpty {
                    ContentUnavailableView("Nothing here", systemImage: "film", description: Text("This category is empty."))
                } else {
                    ContentUnavailableView.search(text: query)
                }
            case let list?:
                ForEach(list) { item in
                    NavigationLink(value: Self.route(item)) { LibraryRow(item: item) }
                        .contextMenu {
                            Button {
                                collecting = CollectableItem(key: item.key, title: item.name)
                            } label: {
                                Label("Add to collection", systemImage: "rectangle.stack.badge.plus")
                            }
                            if let scope = LockScope.item(for: item.key.kind) {
                                LockMenuButton(scope: scope, remoteID: item.key.remoteID, isLocked: app.parental.lockSet.contains(scope, item.key.remoteID))
                            }
                        }
                }
            }
        }
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: Text("Search in this category"))
        .sheet(item: $collecting) { item in
            AddToCollectionView(item: item, catalog: catalog)
        }
        .task(id: library.catalogRevision) {
            items = await library.items(kind: category.kind, categoryID: category.remoteID)
        }
        .task(id: query) {
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { results = nil; return }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            results = await library.search(kind: category.kind, query: query, categoryID: category.remoteID)?.items ?? []
        }
    }

    static func route(_ item: SeyrileoKit.LibraryItem) -> LibraryRoute {
        switch item {
        case .movie(let movie): .movie(movie)
        case .series(let series): .series(series)
        }
    }
}

struct LibraryRow: View {
    let item: SeyrileoKit.LibraryItem
    @Environment(AppModel.self) private var app

    var body: some View {
        if app.parental.isMasked(item.key, categoryIDs: item.categoryIDs) {
            LockedRow(title: "Locked title")
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            PosterImage(url: item.posterURL, title: item.name, width: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name.isEmpty ? String(localized: "Untitled") : item.name)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    switch item {
                    case .movie(let movie):
                        if let rating = movie.rating { Label(rating, systemImage: "star").labelStyle(.titleAndIcon) }
                        if let ext = movie.containerExtension { Text(ext.uppercased()) }
                    case .series(let series):
                        if let genre = series.genre { Text(genre).lineLimit(1) }
                        if let rating = series.rating { Label(rating, systemImage: "star").labelStyle(.titleAndIcon) }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct ProgressLine: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25))
                Capsule().fill(Color.accent).frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityLabel(Text("Watched"))
        .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
    }
}

enum DurationText {
    static func format(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let style: Duration.TimeFormatStyle = seconds >= 3600 ? .time(pattern: .hourMinuteSecond) : .time(pattern: .minuteSecond)
        return Duration.seconds(seconds).formatted(style)
    }
}
