import SeyrileoKit
import SwiftUI

/// Local, indexed search of the active source: live channels, movies or series, each with an
/// optional category filter. Turkish characters and case are optional.
struct SearchView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationStack {
            Group {
                if let catalog = app.activeCatalog, let library = app.activeLibrary {
                    CatalogSearch(catalog: catalog, library: library)
                        .id(catalog.source.id)
                } else {
                    ContentUnavailableView(
                        "No source selected", systemImage: "antenna.radiowaves.left.and.right",
                        description: Text("Add or select a source in Settings."))
                }
            }
            .navigationTitle("Search")
        }
    }
}

private struct CatalogSearch: View {
    let catalog: SourceCatalogModel
    let library: LibraryCatalogModel
    @State private var scope: MediaKind = .live
    @State private var search: ChannelSearchController?
    @State private var query = ""
    @State private var categoryID: String?
    @State private var libraryResults: (items: [SeyrileoKit.LibraryItem], isTruncated: Bool)?
    @State private var player = PlayerLauncher()

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    private var categoryOptions: [(id: String, name: String)] {
        switch scope {
        case .live: catalog.categories.map { ($0.id, $0.category.name) }
        default: library.categories(scope).map { ($0.id, $0.category.name) }
        }
    }

    private var categoryName: String? {
        categoryID.flatMap { id in categoryOptions.first { $0.id == id }?.name }
    }

    private var hasCatalog: Bool {
        scope == .live ? catalog.status?.hasCatalog == true : library.status?.hasCatalog == true
    }

    var body: some View {
        List {
            Section {
                Picker("Search in", selection: $scope) {
                    Text("Live").tag(MediaKind.live)
                    Text("Movies").tag(MediaKind.movie)
                    Text("Series").tag(MediaKind.series)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if !hasCatalog {
                if scope == .live { RefreshStatusSection(catalog: catalog) } else { LibraryStatusSection(library: library) }
                ContentUnavailableView("No saved catalogue yet", systemImage: "tray", description: Text("Search works on the downloaded catalogue. It will be available after the first update."))
            } else if trimmedQuery.isEmpty {
                ContentUnavailableView(
                    scope == .live ? "Search live channels" : (scope == .movie ? "Search movies" : "Search series"),
                    systemImage: "magnifyingglass",
                    description: Text("Type a name. Turkish characters are optional: “cagri” finds “Çağrı”."))
            } else if scope == .live, let search {
                SearchResultsSection(
                    phase: search.phase, query: query, catalog: catalog, player: player, scopeName: categoryName,
                    clearScope: categoryID == nil ? nil : { categoryID = nil })
            } else if scope != .live {
                libraryResultsSection
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Name"))
        #if DEBUG
        .onAppear {
            // `-SeyrileoDebugSeriesSearch <text>`: prefill a series search (simulator checks only).
            let arguments = ProcessInfo.processInfo.arguments
            if query.isEmpty, let index = arguments.firstIndex(of: "-SeyrileoDebugSeriesSearch"), index + 1 < arguments.count {
                scope = .series
                query = arguments[index + 1]
            }
        }
        #endif
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker(selection: $categoryID) {
                        Text("All categories").tag(String?.none)
                        ForEach(categoryOptions, id: \.id) { option in
                            Text(option.name).tag(Optional(option.id))
                        }
                    } label: {
                        Text("Category")
                    }
                } label: {
                    Label("Filter by category", systemImage: categoryID == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
            }
        }
        .safeAreaInset(edge: .top) {
            if let categoryName {
                HStack {
                    Label(categoryName, systemImage: "line.3.horizontal.decrease")
                        .font(.footnote)
                        .lineLimit(1)
                    Spacer()
                    Button("Clear filter") { categoryID = nil }.font(.footnote)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.bar)
            }
        }
        .onChange(of: scope) { _, newScope in
            categoryID = nil
            if newScope != .live { Task { await library.start() } }
        }
        .onChange(of: query) { _, value in search?.query = value }
        .onChange(of: categoryID) { _, value in if scope == .live { search?.categoryID = value } }
        .task(id: catalog.catalogRevision) {
            if search == nil { search = catalog.makeSearchController() }
            search?.refresh()
        }
        .task(id: LibraryQuery(scope: scope, query: trimmedQuery, categoryID: categoryID, revision: library.catalogRevision)) {
            guard scope != .live, !trimmedQuery.isEmpty else { libraryResults = nil; return }
            libraryResults = nil
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            libraryResults = await library.search(kind: scope, query: trimmedQuery, categoryID: categoryID) ?? ([], false)
        }
        .libraryDestinations(library: library, catalog: catalog)
        .playerPresentation(player, catalog: catalog)
    }

    @ViewBuilder
    private var libraryResultsSection: some View {
        if let results = libraryResults {
            if results.items.isEmpty {
                VStack(spacing: 12) {
                    ContentUnavailableView.search(text: query)
                    if let categoryName {
                        Text("Searched only in “\(categoryName)”.").font(.footnote).foregroundStyle(.secondary)
                        Button("Search all categories") { categoryID = nil }
                    }
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(results.items) { item in
                        NavigationLink(value: Self.route(item)) { LibraryRow(item: item) }
                    }
                } footer: {
                    if results.isTruncated { Text("Showing the first \(results.items.count) results. Type more to narrow down.") }
                }
            }
        } else {
            LoadingRow(text: "Searching…")
        }
    }

    static func route(_ item: SeyrileoKit.LibraryItem) -> LibraryRoute {
        switch item {
        case .movie(let movie): .movie(movie)
        case .series(let series): .series(series)
        }
    }
}

private struct LibraryQuery: Hashable {
    let scope: MediaKind
    let query: String
    let categoryID: String?
    let revision: Int
}
