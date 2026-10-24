import LocalAuthentication
import SeyrileoKit
import SwiftUI

// MARK: - PIN prompt

/// Shows the PIN prompt when this is the topmost registered presenter (root, or the player).
private struct ParentalPromptPresenter: ViewModifier {
    @Environment(AppModel.self) private var app
    @State private var id = UUID()

    func body(content: Content) -> some View {
        let parental = app.parental
        content
            .onAppear { parental.register(id) }
            .onDisappear { parental.unregister(id) }
            .sheet(isPresented: Binding(
                get: { parental.request != nil && parental.presenters.last == id },
                set: { if !$0 { parental.finishRequest(unlocked: false) } }
            )) {
                PINPromptView(parental: parental)
            }
    }
}

extension View {
    func parentalPrompt() -> some View { modifier(ParentalPromptPresenter()) }
}

struct PINPromptView: View {
    let parental: ParentalModel
    @State private var pin = ""
    @State private var message: LocalizedStringResource?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("PIN", text: $pin)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .focused($focused)
                        .onChange(of: pin) { _, value in
                            pin = String(value.filter(\.isNumber).prefix(6))
                        }
                        .accessibilityIdentifier("parental.pin")
                } header: {
                    Text("This content is protected by parental controls.")
                } footer: {
                    if let message { Text(app: message).foregroundStyle(.red) }
                }
                if parental.usesBiometrics, parental.biometryType != .none {
                    Section {
                        Button {
                            Task {
                                if await parental.authenticateWithBiometrics() { parental.finishRequest(unlocked: true) }
                            }
                        } label: {
                            Label(parental.biometryType == .faceID ? "Use Face ID" : "Use Touch ID",
                                  systemImage: parental.biometryType == .faceID ? "faceid" : "touchid")
                        }
                    }
                }
            }
            .navigationTitle("Enter PIN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { parental.finishRequest(unlocked: false) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Unlock", action: submit).disabled(pin.count < 4)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(false)
    }

    private func submit() {
        switch parental.gate.verify(pin) {
        case .unlocked:
            parental.finishRequest(unlocked: true)
        case .wrong(let remaining):
            pin = ""
            if remaining > 0 {
                message = "Wrong PIN. \(remaining) attempts left before a short wait."
            } else {
                message = "Wrong PIN."
            }
        case .lockedOut(let until):
            pin = ""
            message = "Too many wrong attempts. Try again \(until.formatted(.relative(presentation: .named)))."
        }
    }
}

// MARK: - Setting a PIN

struct PINSetupView: View {
    enum Mode { case create, change, remove }

    let parental: ParentalModel
    let mode: Mode
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var message: LocalizedStringResource?

    var body: some View {
        NavigationStack {
            Form {
                if mode != .create {
                    Section("Current PIN") {
                        SecureField("Current PIN", text: digits($current)).keyboardType(.numberPad)
                            .accessibilityIdentifier("parental.current")
                    }
                }
                if mode != .remove {
                    Section {
                        SecureField("New PIN (4–6 digits)", text: digits($new)).keyboardType(.numberPad)
                            .accessibilityIdentifier("parental.new")
                        SecureField("Repeat new PIN", text: digits($confirm)).keyboardType(.numberPad)
                            .accessibilityIdentifier("parental.confirm")
                    } footer: {
                        Text("The PIN is stored only on this device, as a one-way hash. If you forget it, remove it with Face ID or Touch ID.")
                    }
                }
                if let message {
                    Section { Text(app: message).foregroundStyle(.red) }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
        }
    }

    private var title: LocalizedStringKey {
        switch mode {
        case .create: "Create PIN"
        case .change: "Change PIN"
        case .remove: "Remove PIN"
        }
    }

    private func digits(_ binding: Binding<String>) -> Binding<String> {
        Binding(get: { binding.wrappedValue }, set: { binding.wrappedValue = String($0.filter(\.isNumber).prefix(6)) })
    }

    private func save() {
        do {
            switch mode {
            case .create, .change:
                guard PINRecord.isValid(new) else { message = "Use 4 to 6 digits."; return }
                guard new == confirm else { message = "The two PINs don't match."; return }
                try parental.gate.setPIN(new, current: mode == .change ? current : nil)
            case .remove:
                try parental.gate.removePIN(current: current)
            }
            dismiss()
        } catch ParentalGate.ChangeError.wrongCurrentPIN {
            message = "The current PIN is wrong."
            current = ""
        } catch ParentalGate.ChangeError.lockedOut(let until) {
            message = "Too many wrong attempts. Try again \(until.formatted(.relative(presentation: .named)))."
        } catch {
            message = "The PIN could not be saved on this device."
        }
    }
}

// MARK: - Settings

struct ParentalSettingsSection: View {
    @Environment(AppModel.self) private var app
    /// Owned by the screen: a sheet attached to a List section can be dismissed by row reloads.
    @Binding var setup: PINSetupView.Mode?

    var body: some View {
        let parental = app.parental
        Section {
            if parental.gate.isEnabled {
                LabeledContent("Status") {
                    Text(parental.isRestricting ? "Locked" : "Unlocked")
                }
                if !parental.isRestricting {
                    Button("Lock now", systemImage: "lock") { parental.lockNow() }
                }
                if parental.biometryType != .none {
                    Toggle(parental.biometryType == .faceID ? "Unlock with Face ID" : "Unlock with Touch ID",
                           isOn: Binding(get: { parental.usesBiometrics }, set: { parental.usesBiometrics = $0 }))
                }
                NavigationLink {
                    LockedContentView()
                } label: {
                    Label("Locked categories", systemImage: "lock.rectangle.stack")
                }
                Button("Change PIN") { setup = .change }
                Button("Remove PIN", role: .destructive) { setup = .remove }
                Button("Forgot PIN? Remove it with Face ID / Touch ID") {
                    Task {
                        let context = LAContext()
                        let reason = String(app: "Remove the parental controls PIN.")
                        if (try? await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)) == true {
                            try? parental.gate.removePIN(current: nil, authorized: true)
                        }
                    }
                }
                .font(.footnote)
            } else {
                Button("Create PIN", systemImage: "lock.badge.plus") { setup = .create }
            }
        } header: {
            Text("Parental controls")
        } footer: {
            Text("Locked categories, channels, films and series are hidden and can't be played until the PIN is entered. Controls lock again whenever Seyrileo goes to the background.")
        }
    }
}

extension PINSetupView.Mode: Identifiable {
    var id: Self { self }
}

/// Lock or unlock whole categories of the active source. Opening it needs the PIN.
struct LockedContentView: View {
    @Environment(AppModel.self) private var app
    @State private var unlocked = false
    @State private var kind: MediaKind = .live

    var body: some View {
        let parental = app.parental
        BrandList {
            if unlocked {
                Picker("Type", selection: $kind) {
                    Text("Live").tag(MediaKind.live)
                    Text("Movies").tag(MediaKind.movie)
                    Text("Series").tag(MediaKind.series)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                ForEach(categories, id: \.id) { category in
                    Toggle(isOn: Binding(
                        get: { parental.isLocked(categoryID: category.id, kind: kind) },
                        set: { value in
                            Task {
                                guard let scope = LockScope.category(for: kind) else { return }
                                await parental.setLocked(value, scope: scope, remoteID: category.id)
                            }
                        }
                    )) {
                        Text(category.name.isEmpty ? String(app: "Untitled category") : category.name)
                    }
                }
            } else {
                ContentUnavailableView("Enter the PIN", systemImage: "lock", description: Text("The PIN is needed to change what is locked."))
            }
        }
        .navigationTitle("Locked categories")
        .task {
            unlocked = await parental.requireUnlock()
        }
    }

    private var categories: [(id: String, name: String)] {
        switch kind {
        case .live: (app.activeCatalog?.categories ?? []).map { ($0.id, $0.category.name) }
        default: (app.activeLibrary?.categories(kind) ?? []).map { ($0.id, $0.category.name) }
        }
    }
}

// MARK: - Guard for locked screens

/// Replaces a locked screen (category, film, series) with an unlock prompt while restricted.
struct ParentalGuard<Content: View>: View {
    @Environment(AppModel.self) private var app
    let isLocked: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        if isLocked, app.parental.isRestricting {
            ContentUnavailableView {
                Label("Locked", systemImage: "lock.fill")
            } description: {
                Text("This content is protected by parental controls.")
            } actions: {
                Button("Unlock") { Task { _ = await app.parental.requireUnlock() } }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            content()
        }
    }
}

/// Lock / unlock menu item; shown only when a PIN exists.
struct LockMenuButton: View {
    @Environment(AppModel.self) private var app
    let scope: LockScope
    let remoteID: String
    let isLocked: Bool

    var body: some View {
        if app.parental.gate.isEnabled {
            Button {
                Task { await app.parental.setLocked(!isLocked, scope: scope, remoteID: remoteID) }
            } label: {
                if isLocked {
                    Label("Remove lock", systemImage: "lock.open")
                } else {
                    Label("Lock", systemImage: "lock")
                }
            }
        }
    }
}
