import SeyrileoKit
import SwiftUI

struct SourceSetupView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var splitPastedLink = false
    @State private var phase: Phase = .editing
    @State private var testTask: Task<Void, Never>?
    @FocusState private var focus: Field?

    enum Field { case name, address, username, password }

    enum Phase {
        case editing
        case testing
        case failed(UserIssue)
        /// Verified, but the provider reports a state in which playback will likely fail.
        case warning(ProviderSource, XtreamCredentials, AccountInfo)
    }

    private var endpoint: XtreamEndpoint? { try? XtreamEndpoint(serverAddress: address) }
    private var isHTTP: Bool { endpoint.map { !$0.usesHTTPS } ?? false }
    private var isTesting: Bool { if case .testing = phase { true } else { false } }
    private var canSubmit: Bool {
        endpoint != nil && !username.isEmpty && !password.isEmpty && !isTesting
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. Home)", text: $name)
                        .focused($focus, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focus = .address }
                    TextField("Server address", text: $address, prompt: Text(verbatim: "https://tv.example.com:8080"))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .address)
                        .submitLabel(.next)
                        .onSubmit { focus = .username }
                        .onChange(of: address) { _, newValue in splitPastedLinkIfNeeded(newValue) }
                } header: {
                    Text("Source")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if splitPastedLink {
                            Text("We split the pasted link into separate fields so your password isn't kept inside an address.")
                        }
                        if isHTTP {
                            Label {
                                Text("Unencrypted connection (HTTP): your username, password and what you watch are sent without encryption and could be seen on the network. Use an HTTPS address if your provider offers one.")
                            } icon: {
                                Image(systemName: "lock.open.trianglebadge.exclamationmark").foregroundStyle(.orange)
                            }
                        }
                    }
                }

                Section {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                    HStack {
                        Group {
                            if showPassword {
                                TextField("Password", text: $password)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            } else {
                                SecureField("Password", text: $password)
                            }
                        }
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .submitLabel(.go)
                        .onSubmit(testAndSave)
                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(showPassword ? Text("Hide password") : Text("Show password"))
                    }
                } header: {
                    Text("Provider sign-in")
                } footer: {
                    Text("These are your provider's details, not a Seyrileo account. They're stored only in this device's Keychain.")
                }

                switch phase {
                case .editing:
                    EmptyView()
                case .testing:
                    Section { LoadingRow(text: "Testing connection…") }
                case .failed(let issue):
                    Section { IssueView(issue: issue) }
                case .warning(let source, let credentials, let account):
                    Section {
                        Label {
                            Text("Connected, but the provider reports this account as \(account.status.localizedName). Playback will probably fail.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        Button("Save anyway") { Task { await save(source, credentials) } }
                    }
                }
            }
            .navigationTitle("Add source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Test & Save", action: testAndSave)
                        .disabled(!canSubmit)
                }
            }
            .onAppear { focus = .name }
            .onDisappear { testTask?.cancel() }
            .interactiveDismissDisabled(isTesting)
        }
    }

    private func splitPastedLinkIfNeeded(_ value: String) {
        guard let parsed = XtreamLinkParser.parse(value) else { return }
        address = parsed.serverAddress
        if let user = parsed.username, username.isEmpty { username = user }
        if let pass = parsed.password, password.isEmpty { password = pass }
        splitPastedLink = true
    }

    private func testAndSave() {
        guard canSubmit else { return }
        let endpoint: XtreamEndpoint
        do {
            endpoint = try XtreamEndpoint(serverAddress: address)
        } catch {
            phase = .failed(UserIssue(error))
            return
        }
        let credentials = XtreamCredentials(username: username, password: password)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = ProviderSource(
            name: trimmedName.isEmpty ? (endpoint.baseURL.host ?? String(app: "My source")) : trimmedName,
            kind: .xtream, serverURL: endpoint.baseURL)
        phase = .testing
        focus = nil
        testTask = Task {
            do {
                let account = try await app.makeClient(endpoint: endpoint, credentials: credentials, providerID: source.id).authenticate()
                if account.status.blocksPlayback {
                    phase = .warning(source, credentials, account)
                } else {
                    await save(source, credentials)
                }
            } catch is CancellationError {
                phase = .editing
            } catch {
                phase = .failed(UserIssue(error))
            }
        }
    }

    private func save(_ source: ProviderSource, _ credentials: XtreamCredentials) async {
        do {
            try await app.save(source, credentials: credentials)
            dismiss()
        } catch {
            phase = .failed(UserIssue(
                title: "Couldn't save the source",
                detail: "The sign-in details could not be stored in this device's Keychain.",
                technical: String(describing: error)))
        }
    }
}
