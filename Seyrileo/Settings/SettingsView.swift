import SeyrileoKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var showSetup = false
    @State private var pendingRemoval: ProviderSource?
    @State private var confirmRemoveAll = false
    @State private var connectionResult: LoadPhase<AccountInfo> = .idle
    @State private var issue: UserIssue?
    @State private var pinSetup: PINSetupView.Mode?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    AboutHeader()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                Section {
                    ForEach(app.sources) { source in
                        Button {
                            app.activate(source)
                            connectionResult = .idle
                        } label: {
                            SourceRow(source: source, isActive: source.id == app.activeSource?.id)
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button("Remove", role: .destructive) { pendingRemoval = source }
                        }
                    }
                    Button {
                        showSetup = true
                    } label: {
                        Label("Add source", systemImage: "plus")
                    }
                    if !app.hasFixtureSource {
                        Button {
                            Task {
                                do { try await app.addFixtureSource() } catch { issue = UserIssue(error) }
                            }
                        } label: {
                            Label("Add the sample experience", systemImage: "testtube.2")
                        }
                    }
                } header: {
                    Text("Sources")
                } footer: {
                    Text("Tap a source to make it active. Swipe to remove it.")
                }

                if let active = app.activeSource {
                    Section {
                        Button {
                            Task { await testConnection() }
                        } label: {
                            Label("Test connection", systemImage: "bolt.horizontal.circle")
                        }
                        switch connectionResult {
                        case .idle: EmptyView()
                        case .loading: LoadingRow(text: "Testing connection…")
                        case .failed(let issue): IssueView(issue: issue) { Task { await testConnection() } }
                        case .loaded(let account):
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Connected")
                                    Text("Account status: \(account.status.localizedName) · Connections: \(DiagnosticsSheet.connections(account))")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                        }
                    } header: {
                        Text("Connection")
                    } footer: {
                        Text("Server: \(Redactor.describe(active.serverURL))")
                    }
                }

                ParentalSettingsSection(setup: $pinSetup)

                if let catalog = app.activeCatalog {
                    Section {
                        if let status = catalog.status, status.hasCatalog {
                            LabeledContent("Live channels", value: status.channelCount.formatted())
                            LabeledContent("Categories", value: status.categoryCount.formatted())
                        }
                        RefreshStatusSection(catalog: catalog)
                        Button {
                            catalog.refresh()
                        } label: {
                            Label("Update catalogue now", systemImage: "arrow.clockwise")
                        }
                        .disabled(catalog.refreshState == .refreshing)
                    } header: {
                        Text("Saved catalogue")
                    } footer: {
                        Text("The catalogue is saved on this device and opens instantly. It updates automatically when it is older than 6 hours. A failed update keeps the saved catalogue.")
                    }
                }

                if let catalog = app.activeCatalog {
                    Section {
                        Stepper(value: Binding(
                            get: { catalog.epgOffsetHours },
                            set: { value in Task { await catalog.setEPGOffset(hours: value) } }), in: -12...12) {
                            LabeledContent("Time correction", value: catalog.epgOffsetHours == 0
                                ? String(localized: "None") : String(localized: "\(catalog.epgOffsetHours, format: .number.sign(strategy: .always())) h"))
                        }
                    } header: {
                        Text("TV guide")
                    } footer: {
                        Text("Guide times are shown in your time zone. Only change this if programmes of this source are consistently early or late.")
                    }
                }

                if let library = app.activeLibrary {
                    Section {
                        if let status = library.status, status.hasCatalog {
                            LabeledContent("Movies", value: status.movieCount.formatted())
                            LabeledContent("Series", value: status.seriesCount.formatted())
                        }
                        LibraryStatusSection(library: library)
                        Button {
                            library.refresh()
                        } label: {
                            Label("Update movies and series now", systemImage: "arrow.clockwise")
                        }
                        .disabled(library.refreshState == .refreshing)
                    } header: {
                        Text("Movies and series")
                    } footer: {
                        Text("Downloaded when you first open the Library, then updated when older than 12 hours. Details are loaded only when you open a title.")
                    }
                    .task { await library.loadCache() }
                }

                if let issue {
                    Section { IssueView(issue: issue) }
                }

                Section {
                    Button("Remove all data", role: .destructive) { confirmRemoveAll = true }
                } header: {
                    Text("Data")
                } footer: {
                    Text("Removes every source from this device, including saved catalogues, favorites, history and sign-in details stored in the Keychain.")
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.shortVersion)
                    NavigationLink("Open-source licenses") { LicensesView() }
                    Text("Seyrileo is a media player. It doesn't provide channels, subscriptions or content.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showSetup) { SourceSetupView() }
            .confirmationDialog(
                "Remove this source?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                titleVisibility: .visible, presenting: pendingRemoval
            ) { source in
                Button("Remove", role: .destructive) { Task { await remove(source) } }
            } message: { _ in
                Text("Its saved catalogue, favorites and history are deleted, and its sign-in details are removed from this device's Keychain.")
            }
            .confirmationDialog("Remove all data?", isPresented: $confirmRemoveAll, titleVisibility: .visible) {
                Button("Remove all data", role: .destructive) {
                    Task {
                        do { try await app.removeAllData() } catch { issue = UserIssue(error) }
                    }
                }
            }
            .sheet(item: $pinSetup) { mode in
                PINSetupView(parental: app.parental, mode: mode)
            }
        }
    }

    private func remove(_ source: ProviderSource) async {
        do {
            try await app.remove(source)
            connectionResult = .idle
        } catch {
            issue = UserIssue(error)
        }
    }

    private func testConnection() async {
        guard let source = app.activeSource else { return }
        connectionResult = .loading
        do {
            connectionResult = .loaded(try await app.makeClient(for: source).authenticate())
        } catch {
            connectionResult = .failed(UserIssue(error))
        }
    }
}

private struct SourceRow: View {
    let source: ProviderSource
    let isActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: source.isFixture ? "testtube.2" : "antenna.radiowaves.left.and.right")
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                Text(source.isFixture ? String(localized: "Sample · synthetic local data") : Redactor.describe(source.serverURL))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if isActive {
                Image(systemName: "checkmark").foregroundStyle(.tint)
                    .accessibilityLabel(Text("Active"))
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// Brand card at the top of Settings: icon, name and version.
private struct AboutHeader: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        ZStack {
            BrandBackdrop()
            VStack(spacing: 10) {
                BrandMark(size: 76)
                Text(verbatim: "Seyrileo")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                Text("Version \(version)")
                    .font(.caption)
                    .foregroundStyle(Color.brandCream.opacity(0.75))
            }
            .padding(.vertical, 22)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
