import SeyrileoKit
import SwiftUI

struct LiveView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationStack {
            Group {
                if let catalog = app.activeCatalog {
                    CategoryListView(catalog: catalog)
                } else {
                    ContentUnavailableView(
                        "No source selected", systemImage: "antenna.radiowaves.left.and.right",
                        description: Text("Add or select a source in Settings."))
                }
            }
            .navigationTitle("Live")
        }
        // A new source starts from its own root: never keep another source's category open.
        .id(app.activeCatalog?.source.id)
    }
}

private struct CategoryListView: View {
    @Environment(AppModel.self) private var app
    let catalog: SourceCatalogModel
    @State private var editMode: EditMode = .inactive
    /// Searches channels in every category.
    @State private var search: ChannelSearchController?
    @State private var query = ""
    @State private var player = PlayerLauncher()

    var body: some View {
        BrandList {
            if !query.trimmingCharacters(in: .whitespaces).isEmpty, let search {
                SearchResultsSection(phase: search.phase, query: query, catalog: catalog, player: player)
            } else {
                categoryContent
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Search live channels"))
        .onChange(of: query) { _, value in
            if !value.isEmpty { editMode = .inactive }
            search?.query = value
        }
        .task(id: [catalog.catalogRevision, catalog.organizationRevision]) {
            if search == nil { search = catalog.makeSearchController() }
            search?.refresh()
        }
        .playerPresentation(player, catalog: catalog)
        .navigationDestination(for: LiveCategory.self) { category in
            ChannelListView(catalog: catalog, category: category)
        }
        .navigationDestination(for: GuideRoute.self) { _ in
            GuideOverviewView(catalog: catalog)
        }
        .navigationDestination(for: HiddenItemsRoute.self) { _ in
            HiddenItemsView(catalog: catalog)
        }
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: GuideRoute()) {
                    Label("Guide", systemImage: "calendar")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if editMode.isEditing {
                    Button("Done") { editMode = .inactive }
                } else {
                    Menu {
                        Button("Reorder categories", systemImage: "arrow.up.arrow.down") {
                            if app.pro.require(app.pro.isPro, for: .advancedOrganization) { editMode = .active }
                        }
                            .disabled(catalog.categories.count < 2)
                        Button("Restore provider order", systemImage: "arrow.uturn.backward") {
                            Task { await catalog.resetCategoryOrder() }
                        }
                        NavigationLink(value: HiddenItemsRoute()) {
                            Label("Hidden channels and categories", systemImage: "eye.slash")
                        }
                    } label: {
                        Label("Organize", systemImage: "ellipsis")
                    }
                }
            }
        }
        .refreshable { await catalog.refreshAndWait() }
    }

    /// The category list (with the sample banner and refresh state) while not searching.
    @ViewBuilder
    private var categoryContent: some View {
        if catalog.source.isFixture {
            Section { FixtureBanner() }
        }
        if let error = app.fixtureServerError, catalog.source.isFixture {
            Section {
                Label("The on-device sample server could not start: \(error)", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
            }
        }
        AccountWarningSection(account: catalog.account)
        RefreshStatusSection(catalog: catalog)
        if catalog.hasLoadedCache, catalog.status?.hasCatalog == true {
            if catalog.categories.isEmpty {
                ContentUnavailableView("No live categories", systemImage: "tray", description: Text("This source has no live TV categories."))
            } else {
                Section {
                    ForEach(catalog.categories) { summary in
                        let locked = app.parental.isLocked(categoryID: summary.id, kind: .live)
                        NavigationLink(value: summary.category) {
                            LabeledContent {
                                Text(summary.channelCount, format: .number)
                            } label: {
                                CategoryTitle(name: summary.category.name, isLocked: locked, isMasked: locked && app.parental.isRestricting)
                            }
                        }
                        .swipeActions {
                            Button("Hide", systemImage: "eye.slash") {
                                guard app.pro.require(app.pro.isPro, for: .advancedOrganization) else { return }
                                Task { await catalog.setHidden(true, category: summary.category) }
                            }
                            .tint(.gray)
                            if app.parental.gate.isEnabled {
                                Button(locked ? "Remove lock" : "Lock", systemImage: locked ? "lock.open" : "lock") {
                                    Task { await app.parental.setLocked(!locked, scope: .liveCategory, remoteID: summary.id) }
                                }
                                .tint(.indigo)
                            }
                        }
                    }
                    .onMove(perform: categoryMove)
                } footer: {
                    DroppedFooter(count: catalog.status?.droppedCount ?? 0)
                }
            }
        }
    }

    private var categoryMove: ((IndexSet, Int) -> Void)? {
        guard editMode.isEditing else { return nil }
        return { moveCategories(from: $0, to: $1) }
    }

    private func moveCategories(from: IndexSet, to: Int) {
        var list = catalog.categories
        list.move(fromOffsets: from, toOffset: to)
        Task { await catalog.setCategoryOrder(list) }
    }
}

/// Shows the state of the background catalogue update separately from the saved catalogue.
struct RefreshStatusSection: View {
    let catalog: SourceCatalogModel

    var body: some View {
        let hasCatalog = catalog.status?.hasCatalog == true
        switch catalog.refreshState {
        case .refreshing:
            if hasCatalog {
                Section { Label { Text("Updating catalogue…") } icon: { PawLoader(size: 12) }.font(.footnote) }
            } else {
                LoadingRow(text: "Downloading the catalogue…")
            }
        case .failed(let issue):
            if hasCatalog {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Couldn't update. Showing the saved catalogue.", systemImage: "exclamationmark.arrow.circlepath")
                            .font(.footnote.weight(.semibold))
                        Text(app: issue.title).font(.footnote).foregroundStyle(.secondary)
                        Button("Try again") { catalog.refresh() }.font(.footnote)
                    }
                }
            } else {
                IssueView(issue: issue) { catalog.refresh() }
            }
        case .idle:
            if !catalog.hasLoadedCache {
                LoadingRow(text: "Loading categories…")
            } else if let date = catalog.status?.lastSuccessAt {
                Section {
                    Text("Updated \(date, format: .relative(presentation: .named))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if catalog.status?.lastErrorCode != nil {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("The last catalogue update failed.").font(.footnote)
                        Button("Try again") { catalog.refresh() }.font(.footnote)
                    }
                }
            }
        }
    }
}

private struct ChannelListView: View {
    let catalog: SourceCatalogModel
    let category: LiveCategory
    @State private var channels: [LiveChannel]?
    @State private var search: ChannelSearchController?
    @State private var query = ""
    @State private var player = PlayerLauncher()
    @State private var editMode: EditMode = .inactive
    @State private var hasCustomOrder = false
    @Environment(AppModel.self) private var app

    private var isMasked: Bool { app.parental.isMasked(categoryID: category.remoteID, kind: .live) }

    var body: some View {
        ParentalGuard(isLocked: app.parental.isLocked(categoryID: category.remoteID, kind: .live)) {
            channelList
        }
    }

    private var channelList: some View {
        BrandList {
            if !query.isEmpty, let search {
                SearchResultsSection(phase: search.phase, query: query, catalog: catalog, player: player, scopeName: category.name)
            } else {
                switch channels {
                case nil:
                    LoadingRow(text: "Loading channels…")
                case let channels? where channels.isEmpty:
                    ContentUnavailableView("No channels", systemImage: "tv", description: Text("This category is empty."))
                case let channels?:
                    ForEach(channels) { channel in
                        ChannelButton(channel: channel, list: channels, catalog: catalog, player: player)
                    }
                    .onMove(perform: channelMove)
                }
            }
        }
        .navigationTitle(isMasked ? String(app: "Locked category") : category.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: Text("Search in this category"))
        .onChange(of: query) { _, value in search?.query = value }
        .environment(\.editMode, $editMode)
        .toolbar {
            if editMode.isEditing {
                Button("Done") { editMode = .inactive }
            } else if (channels?.count ?? 0) > 1 {
                Menu {
                    Button("Reorder channels", systemImage: "arrow.up.arrow.down") {
                        guard app.pro.require(app.pro.isPro, for: .advancedOrganization) else { return }
                        query = ""
                        editMode = .active
                    }
                    if hasCustomOrder {
                        Button("Restore provider order", systemImage: "arrow.uturn.backward") {
                            Task { await catalog.resetChannelOrder(in: category.remoteID) }
                        }
                    }
                } label: {
                    Label("Organize", systemImage: "ellipsis")
                }
            }
        }
        .task(id: [catalog.catalogRevision, catalog.organizationRevision]) {
            if search == nil { search = catalog.makeSearchController(categoryID: category.remoteID) }
            channels = await catalog.channels(inCategory: category.remoteID)
            hasCustomOrder = await catalog.hasCustomChannelOrder(in: category.remoteID)
            search?.refresh()
        }
        .playerPresentation(player, catalog: catalog)
    }

    private var channelMove: ((IndexSet, Int) -> Void)? {
        guard editMode.isEditing else { return nil }
        return { moveChannels(from: $0, to: $1) }
    }

    private func moveChannels(from: IndexSet, to: Int) {
        guard var list = channels else { return }
        list.move(fromOffsets: from, toOffset: to)
        channels = list
        Task { await catalog.setChannelOrder(list, in: category.remoteID) }
    }
}

/// Results for a debounced local search, with clear empty states.
struct SearchResultsSection: View {
    let phase: ChannelSearchController.Phase
    let query: String
    let catalog: SourceCatalogModel
    let player: PlayerLauncher
    var scopeName: String?
    var clearScope: (() -> Void)?

    var body: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .searching:
            LoadingRow(text: "Searching…")
        case .failed:
            ContentUnavailableView("Search failed", systemImage: "exclamationmark.magnifyingglass", description: Text("The saved catalogue could not be searched."))
        case .results(let results, let truncated):
            if results.isEmpty {
                VStack(spacing: 12) {
                    ContentUnavailableView.search(text: query)
                    if let scopeName {
                        Text("Searched only in “\(scopeName)”.").font(.footnote).foregroundStyle(.secondary)
                        if let clearScope {
                            Button("Search all categories", action: clearScope)
                        }
                    }
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(results) { channel in
                        ChannelButton(channel: channel, list: results, catalog: catalog, player: player)
                    }
                } footer: {
                    if truncated { Text("Showing the first \(results.count) results. Type more to narrow down.") }
                }
            }
        }
    }
}

/// A channel row that plays on tap and offers favorite actions.
struct ChannelButton: View {
    let channel: LiveChannel
    let list: [LiveChannel]
    let catalog: SourceCatalogModel
    let player: PlayerLauncher
    @State private var showGuide = false
    @State private var renaming: LiveChannel?
    @State private var collecting: CollectableItem?
    @Environment(AppModel.self) private var app

    var body: some View {
        let isFavorite = catalog.isFavorite(channel.key)
        Button { player.play(channel, in: list, catalog: catalog) } label: {
            ChannelRow(channel: channel, isFavorite: isFavorite, epg: catalog)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            FavoriteButton(isFavorite: isFavorite) { Task { await catalog.toggleFavorite(channel) } }
                .tint(.yellow)
        }
        .swipeActions(edge: .leading) {
            if channel.epgChannelID != nil, !app.parental.isMasked(channel) {
                Button { showGuide = true } label: { Label("TV guide", systemImage: "calendar") }
                    .tint(.accent)
            }
        }
        .contextMenu {
            FavoriteButton(isFavorite: isFavorite) { Task { await catalog.toggleFavorite(channel) } }
            if channel.epgChannelID != nil, !app.parental.isMasked(channel) {
                Button { showGuide = true } label: { Label("TV guide", systemImage: "calendar") }
            }
            Button {
                collecting = CollectableItem(key: channel.key, title: SourceCatalogModel.title(channel))
            } label: {
                Label("Add to collection", systemImage: "rectangle.stack.badge.plus")
            }
            Button {
                if app.pro.require(app.pro.isPro, for: .advancedOrganization) { renaming = channel }
            } label: { Label("Rename", systemImage: "pencil") }
            LockMenuButton(scope: .live, remoteID: channel.key.remoteID, isLocked: app.parental.lockSet.contains(.live, channel.key.remoteID))
            Button {
                // Showing a hidden channel again is always allowed.
                guard channel.isHidden || app.pro.require(app.pro.isPro, for: .advancedOrganization) else { return }
                Task { await catalog.setHidden(!channel.isHidden, channel: channel) }
            } label: {
                if channel.isHidden {
                    Label("Show channel", systemImage: "eye")
                } else {
                    Label("Hide channel", systemImage: "eye.slash")
                }
            }
        }
        .sheet(isPresented: $showGuide) {
            ChannelGuideView(channel: channel, catalog: catalog) { player.play(channel, in: list, catalog: catalog) }
        }
        .sheet(item: $collecting) { item in
            AddToCollectionView(item: item, catalog: catalog)
        }
        .channelRename($renaming, catalog: catalog)
    }
}

struct FavoriteButton: View {
    let isFavorite: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if isFavorite {
                Label("Remove from favorites", systemImage: "star.slash")
            } else {
                Label("Add to favorites", systemImage: "star")
            }
        }
    }
}

struct ChannelRow: View {
    let channel: LiveChannel
    var isFavorite = false
    var isAvailable = true
    /// When set, the row shows the provider's now/next for channels that have guide data.
    var epg: SourceCatalogModel?

    @Environment(AppModel.self) private var app

    var body: some View {
        if app.parental.isMasked(channel) {
            LockedRow(title: "Locked channel")
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            Monogram(text: channel.displayName)
            VStack(alignment: .leading, spacing: 2) {
                Text(SourceCatalogModel.title(channel))
                    .font(.body)
                    .foregroundStyle(.primary)
                if channel.alias != nil {
                    Text(verbatim: channel.name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityLabel(Text("Provider name: \(channel.name)"))
                }
                if let epg, channel.epgChannelID != nil {
                    NowNextLine(channel: channel, catalog: epg)
                } else if let number = channel.number {
                    Text("Channel \(number)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if isFavorite {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .accessibilityLabel(Text("Favorite"))
            }
            Image(systemName: "play.fill")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Plays this channel"))
    }
}

/// Generated initials instead of provider logos: no remote image loading yet and no
/// third-party artwork in screenshots.
struct Monogram: View {
    let text: String
    /// Grows with Dynamic Type so the initials are never clipped.
    @ScaledMetric(relativeTo: .subheadline) private var side: CGFloat = 44

    private var initials: String {
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(2)
        let letters = words.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "•" : letters.uppercased()
    }

    var body: some View {
        Text(initials)
            .font(.system(.subheadline, design: .rounded).weight(.heavy))
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            .foregroundStyle(Color.brandCream)
            .frame(width: side, height: side)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [Color.accent.opacity(0.28), Color.brandGlow.opacity(0.5)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    }
            }
            .accessibilityHidden(true)
    }
}

struct FixtureBanner: View {
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sample experience").font(.subheadline.weight(.semibold))
                Text("Synthetic test patterns served from this device. These are not real channels.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: "testtube.2").foregroundStyle(.tint)
        }
    }
}

struct AccountWarningSection: View {
    let account: AccountInfo?

    var body: some View {
        if let account, account.status.blocksPlayback {
            Section {
                Label {
                    Text("The provider reports this account as \(account.status.localizedName). Playback will probably fail.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.footnote)
            }
        }
    }
}

struct DroppedFooter: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text("\(count) entries from the provider could not be read and were skipped.")
        }
    }
}

struct LoadingRow: View {
    let text: LocalizedStringKey

    var body: some View {
        HStack(spacing: 12) {
            PawLoader(size: 18)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 24)
        .listRowBackground(Color.clear)
    }
}

extension AccountInfo.Status {
    var localizedName: String {
        switch self {
        case .active: String(app: "active")
        case .expired: String(app: "expired")
        case .banned: String(app: "banned")
        case .disabled: String(app: "disabled")
        case .unknown(let raw): raw ?? String(app: "unknown")
        }
    }
}

struct GuideRoute: Hashable {}

/// Stand-in for content hidden by parental controls: no name, logo or programme.
struct LockedRow: View {
    let title: LocalizedStringKey

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Needs the parental PIN"))
    }
}

struct CategoryTitle: View {
    let name: String
    let isLocked: Bool
    let isMasked: Bool

    var body: some View {
        if isMasked {
            Label("Locked category", systemImage: "lock.fill").foregroundStyle(.secondary)
        } else if isLocked {
            Label(name.isEmpty ? String(app: "Untitled category") : name, systemImage: "lock.open")
        } else {
            Text(name.isEmpty ? String(app: "Untitled category") : name)
        }
    }
}
