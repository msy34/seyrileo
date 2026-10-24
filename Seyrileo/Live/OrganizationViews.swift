import SeyrileoKit
import SwiftUI

// MARK: - Channel alias

/// A small sheet for typing a name. Used instead of an alert text field: sheets keep focus,
/// support Dynamic Type and work reliably with hardware keyboards and UI automation.
struct NameEditorSheet: View {
    let title: LocalizedStringKey
    var message: Text?
    let initial: String
    /// Extra action, e.g. "Use the provider's name".
    var resetTitle: LocalizedStringKey?
    var onReset: (() async -> UserIssue?)?
    let onSave: (String) async -> UserIssue?
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var issue: UserIssue?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $text)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(save)
                        .accessibilityIdentifier("name.field")
                } footer: {
                    message
                }
                if let resetTitle, let onReset {
                    Section {
                        Button(resetTitle) {
                            Task {
                                issue = await onReset()
                                if issue == nil { dismiss() }
                            }
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                text = initial
                focused = true
            }
            .issueAlert($issue)
        }
        .presentationDetents([.medium])
    }

    private func save() {
        let value = text
        Task {
            issue = await onSave(value)
            if issue == nil { dismiss() }
        }
    }
}

/// Rename (local alias). The provider's name is shown so the user always knows what the
/// channel is really called, and can go back to it.
private struct ChannelRenameModifier: ViewModifier {
    @Binding var channel: LiveChannel?
    let catalog: SourceCatalogModel

    func body(content: Content) -> some View {
        content.sheet(item: $channel) { channel in
            NameEditorSheet(
                title: "Rename channel",
                message: Text("Only on this device. Provider name: \(channel.name)"),
                initial: channel.displayName,
                resetTitle: channel.alias != nil ? "Use the provider's name" : nil,
                onReset: { await catalog.setAlias(nil, for: channel) }
            ) { value in
                // Saving the provider's own name is the same as clearing the alias.
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return await catalog.setAlias(trimmed == channel.name ? nil : trimmed, for: channel)
            }
        }
    }
}

extension View {
    func channelRename(_ channel: Binding<LiveChannel?>, catalog: SourceCatalogModel) -> some View {
        modifier(ChannelRenameModifier(channel: channel, catalog: catalog))
    }

    func issueAlert(_ issue: Binding<UserIssue?>) -> some View {
        alert(
            issue.wrappedValue.map { Text(app: $0.title) } ?? Text(verbatim: ""),
            isPresented: Binding(get: { issue.wrappedValue != nil }, set: { if !$0 { issue.wrappedValue = nil } }),
            presenting: issue.wrappedValue
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { issue in
            Text(app: issue.detail)
        }
    }
}

// MARK: - Add to collection

/// Something that can be put in a collection.
struct CollectableItem: Identifiable, Hashable {
    let key: MediaKey
    let title: String
    var id: MediaKey { key }
}

/// Toggle membership of one item in the user's collections, or create a new collection.
struct AddToCollectionView: View {
    @Environment(AppModel.self) private var app
    let item: CollectableItem
    let catalog: SourceCatalogModel
    @Environment(\.dismiss) private var dismiss
    @State private var collections: [UserCollection]?
    @State private var expanded: Set<String> = []
    @Environment(\.editMode) private var editMode
    @State private var memberOf: Set<UUID> = []
    @State private var newName = ""
    @State private var issue: UserIssue?
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            BrandList {
                Section {
                    HStack {
                        TextField("New collection", text: $newName)
                            .focused($nameFocused)
                            .submitLabel(.done)
                            .onSubmit(create)
                        Button("Create", action: create)
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } footer: {
                    Text("For example “Evening sports”. Collections are kept only on this device.")
                }
                if let collections, !collections.isEmpty {
                    Section("Your collections") {
                        ForEach(collections) { collection in
                            let isMember = memberOf.contains(collection.id)
                            Button {
                                Task { await toggle(collection, isMember: !isMember) }
                            } label: {
                                HStack {
                                    Label(collection.name, systemImage: "rectangle.stack")
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if isMember {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                            }
                            .accessibilityAddTraits(isMember ? .isSelected : [])
                        }
                    }
                }
            }
            .navigationTitle("Add to collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await load() }
            .issueAlert($issue)
            .proPaywall()
        }
        .presentationDetents([.medium, .large])
    }

    private func load() async {
        collections = await catalog.collections()
        memberOf = await catalog.collectionIDs(containing: item.key)
        if collections?.isEmpty == true { nameFocused = true }
    }

    private func create() {
        let name = newName
        guard app.pro.require(ProPolicy.canCreateCollection(existing: collections?.count ?? 0, isPro: app.pro.isPro), for: .unlimitedCollections)
        else { return }
        Task {
            do {
                let collection = try await catalog.createCollection(named: name)
                newName = ""
                await toggle(collection, isMember: true)
                await load()
            } catch {
                issue = UserIssue(error)
            }
        }
    }

    private func toggle(_ collection: UserCollection, isMember: Bool) async {
        await catalog.setMembership(isMember, key: item.key, title: item.title, collection: collection)
        if isMember { memberOf.insert(collection.id) } else { memberOf.remove(collection.id) }
    }
}

// MARK: - Collections in Your Space

struct CollectionsSection: View {
    @Environment(AppModel.self) private var app
    let catalog: SourceCatalogModel
    /// Owned by the screen: a sheet attached to a List section does not present reliably.
    @Binding var creating: Bool
    @State private var collections: [UserCollection]?
    @State private var expanded: Set<String> = []
    @Environment(\.editMode) private var editMode

    var body: some View {
        Section {
            if let collections {
                if collections.isEmpty {
                    Text("Group channels, films and series your way. Touch and hold an item and choose “Add to collection”.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                let showsAll = expanded.contains("collections") || editMode?.wrappedValue.isEditing == true
                ForEach(showsAll ? collections[...] : collections.prefix(SectionPreview.limit)) { collection in
                    NavigationLink(value: collection) {
                        LabeledContent {
                            Text(collection.itemCount, format: .number)
                        } label: {
                            Label(collection.name, systemImage: "rectangle.stack")
                        }
                    }
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            Task { await catalog.deleteCollection(collection) }
                        }
                    }
                }
                .onMove { from, to in
                    var list = collections
                    list.move(fromOffsets: from, toOffset: to)
                    self.collections = list
                    Task { await catalog.reorderCollections(list) }
                }
                if editMode?.wrappedValue.isEditing != true {
                    SectionPreview.Toggle(total: collections.count, id: "collections", expanded: $expanded)
                }
            }
            Button {
                if app.pro.require(ProPolicy.canCreateCollection(existing: collections?.count ?? 0, isPro: app.pro.isPro), for: .unlimitedCollections) {
                    creating = true
                }
            } label: {
                Label("New collection", systemImage: "plus")
            }
        } header: {
            Text("Collections")
        }
        .task(id: catalog.organizationRevision) { collections = await catalog.collections() }
    }
}

extension View {
    /// The "New collection" name sheet, attached to a whole screen.
    func newCollectionSheet(isPresented: Binding<Bool>, catalog: SourceCatalogModel) -> some View {
        sheet(isPresented: isPresented) {
            NameEditorSheet(title: "New collection", initial: "") { name in
                do {
                    _ = try await catalog.createCollection(named: name)
                    return nil
                } catch {
                    return UserIssue(error)
                }
            }
        }
    }
}

struct CollectionDetailView: View {
    let collection: UserCollection
    let catalog: SourceCatalogModel
    let library: LibraryCatalogModel
    @Environment(\.dismiss) private var dismiss
    @State private var items: [CollectionEntry]?
    @State private var name: String
    @State private var renaming = false
    @State private var confirmDelete = false
    @State private var issue: UserIssue?
    @State private var player = PlayerLauncher()

    init(collection: UserCollection, catalog: SourceCatalogModel, library: LibraryCatalogModel) {
        self.collection = collection
        self.catalog = catalog
        self.library = library
        _name = State(initialValue: collection.name)
    }

    private var channels: [LiveChannel] { (items ?? []).compactMap(\.channel) }

    var body: some View {
        BrandList {
            switch items {
            case nil:
                LoadingRow(text: "Loading…")
            case let items? where items.isEmpty:
                ContentUnavailableView(
                    "Empty collection", systemImage: "rectangle.stack",
                    description: Text("Touch and hold a channel, film or series and choose “Add to collection”."))
            case let items?:
                ForEach(items) { entry in
                    row(entry)
                        .swipeActions {
                            Button("Remove", systemImage: "minus.circle", role: .destructive) {
                                Task { await catalog.setMembership(false, key: entry.key, title: entry.title, collection: collection) }
                            }
                        }
                }
                .onMove { from, to in
                    var list = items
                    list.move(fromOffsets: from, toOffset: to)
                    self.items = list
                    Task { await catalog.reorderItems(list, in: collection) }
                }
            }
        }
        .navigationTitle(name)
        .toolbar {
            if !(items ?? []).isEmpty { EditButton() }
            Menu {
                Button("Rename", systemImage: "pencil") { renaming = true }
                Button("Delete collection", systemImage: "trash", role: .destructive) { confirmDelete = true }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .accessibilityIdentifier("collection.more")
        }
        .task(id: catalog.organizationRevision) { items = await catalog.items(in: collection) }
        .sheet(isPresented: $renaming) {
            NameEditorSheet(title: "Rename collection", initial: name) { value in
                if let failure = await catalog.renameCollection(collection, to: value) { return failure }
                name = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return nil
            }
        }
        .confirmationDialog("Delete “\(name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete collection", role: .destructive) {
                Task {
                    await catalog.deleteCollection(collection)
                    dismiss()
                }
            }
        } message: {
            Text("The channels and titles stay in your source; only this list is removed.")
        }
        .issueAlert($issue)
        .playerPresentation(player, catalog: catalog)
    }

    @ViewBuilder
    private func row(_ entry: CollectionEntry) -> some View {
        if let channel = entry.channel {
            ChannelButton(channel: channel, list: channels, catalog: catalog, player: player)
        } else if entry.isAvailable, entry.key.kind == .movie || entry.key.kind == .series {
            CollectionMediaRow(entry: entry, library: library)
        } else {
            HStack(spacing: 12) {
                Monogram(text: entry.title)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).foregroundStyle(.secondary)
                    Text("No longer offered by this source").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }
}

/// A film or series in a collection; resolves the saved catalogue entry to open its page.
private struct CollectionMediaRow: View {
    let entry: CollectionEntry
    let library: LibraryCatalogModel
    @State private var route: LibraryRoute?
    @Environment(AppModel.self) private var app

    private var categoryIDs: [String] {
        switch route {
        case .movie(let movie): movie.categoryIDs
        case .series(let series): series.categoryIDs
        default: []
        }
    }

    var body: some View {
        Group {
            if app.parental.isMasked(entry.key, categoryIDs: categoryIDs) {
                if let route {
                    NavigationLink(value: route) { LockedRow(title: "Locked title") }
                } else {
                    LockedRow(title: "Locked title")
                }
            } else if let route {
                NavigationLink(value: route) { label }
            } else {
                label
            }
        }
        .task(id: entry.key) {
            switch entry.key.kind {
            case .movie: route = await library.movie(entry.key).map(LibraryRoute.movie)
            case .series: route = await library.series(entry.key).map(LibraryRoute.series)
            default: route = nil
            }
        }
    }

    private var label: some View {
        HStack(spacing: 12) {
            PosterImage(url: posterURL, title: entry.title, width: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).lineLimit(2)
                Text(entry.key.kind == .movie ? "Film" : "Series").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var posterURL: URL? {
        switch route {
        case .movie(let movie): movie.posterURL
        case .series(let series): series.posterURL
        default: nil
        }
    }
}

// MARK: - Hidden items

/// Everything the user hid, with a way back. Hidden items are not deleted; they are left out
/// of lists, search, the guide and channel switching.
struct HiddenItemsView: View {
    let catalog: SourceCatalogModel
    @State private var channels: [LiveChannel]?
    @State private var categories: [LiveCategory] = []

    var body: some View {
        BrandList {
            if let channels, channels.isEmpty, categories.isEmpty {
                ContentUnavailableView(
                    "Nothing hidden", systemImage: "eye",
                    description: Text("Touch and hold a channel or swipe a category to hide it."))
            }
            if !categories.isEmpty {
                Section("Categories") {
                    ForEach(categories) { category in
                        LabeledContent(category.name.isEmpty ? String(app: "Untitled category") : category.name) {
                            Button("Show") { Task { await catalog.setHidden(false, category: category) } }
                        }
                    }
                }
            }
            if let channels, !channels.isEmpty {
                Section("Channels") {
                    ForEach(channels) { channel in
                        LabeledContent(SourceCatalogModel.title(channel)) {
                            Button("Show") { Task { await catalog.setHidden(false, channel: channel) } }
                        }
                    }
                }
            }
        }
        .navigationTitle("Hidden")
        .task(id: catalog.organizationRevision) {
            categories = await catalog.hiddenCategories()
            channels = await catalog.hiddenChannels()
        }
    }
}

struct HiddenItemsRoute: Hashable {}
