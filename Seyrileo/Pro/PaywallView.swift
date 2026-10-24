import SeyrileoKit
import StoreKit
import SwiftUI

/// The Seyrileo Pro sheet: what it adds, the price from the App Store, buy and restore.
struct PaywallView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let reason: ProFeature?

    private var store: ProStore { app.pro }

    var body: some View {
        NavigationStack {
            ZStack {
                BrandBackdrop()
                ScrollView {
                    VStack(spacing: 22) {
                        BrandMark(size: 112)
                            .padding(.top, 12)
                        VStack(spacing: 6) {
                            (Text(verbatim: "Seyrileo ") + Text(verbatim: "Pro").foregroundStyle(Color.accent))
                                .font(.system(.largeTitle, design: .rounded).weight(.heavy))
                                .foregroundStyle(.white)
                            Text("Curl up. Press play.")
                                .font(.system(.title3, design: .rounded).weight(.semibold))
                                .foregroundStyle(Color.brandCream)
                            if let reason {
                                Text(headline(for: reason))
                                    .font(.callout)
                                    .foregroundStyle(.white.opacity(0.7))
                                    .padding(.top, 4)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        VStack(spacing: 8) {
                            FeatureLine(title: "More than one source")
                            FeatureLine(title: "Unlimited collections")
                            FeatureLine(title: "Rename, hide and reorder channels")
                            FeatureLine(title: "Programme reminders")
                        }
                        .frame(maxWidth: 440)

                        purchaseArea
                            .frame(maxWidth: 440)

                        Text("One-time purchase. No subscription and no ads. Everything else in Seyrileo stays free, and nothing you created is removed.")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 440)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.body.weight(.bold))
                    }
                    .accessibilityLabel(Text("Close"))
                }
            }
            .environment(\.colorScheme, .dark)
        }
        .task { if store.product == nil { await store.loadProduct() } }
        .accessibilityIdentifier("pro.paywall")
    }

    @ViewBuilder
    private var purchaseArea: some View {
        VStack(spacing: 12) {
            if store.hasPurchased {
                Label("Seyrileo Pro is active. Thank you!", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Color.accent)
                    .font(.headline)
            } else if let product = store.product {
                Button {
                    Task { await store.purchase() }
                } label: {
                    HStack {
                        if store.purchaseState == .purchasing { ProgressView().tint(Color.brandNavy) }
                        Text("Unlock for \(product.displayPrice)")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.brandCream)
                .foregroundStyle(Color.brandNavy)
                .controlSize(.large)
                .shadow(color: Color.brandCream.opacity(0.35), radius: 12, y: 6)
                .disabled(store.purchaseState == .purchasing)
            } else if store.productsUnavailable {
                Text("The App Store is not reachable right now, so the price can't be shown. Try again later.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
            } else {
                PawLoader(size: 22, tint: .brandCream)
            }
            switch store.purchaseState {
            case .pending:
                Text("The purchase is waiting for approval (for example Ask to Buy). Pro unlocks when it is approved.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
            case .failed(let message):
                Text(verbatim: message).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
            default:
                EmptyView()
            }
            if !store.hasPurchased {
                Button("Restore purchase") { Task { await store.restore() } }
                    .font(.subheadline)
                    .tint(.white)
            }
        }
    }

    private func headline(for feature: ProFeature) -> LocalizedStringKey {
        switch feature {
        case .multipleSources: "The free version includes one source."
        case .unlimitedCollections: "The free version includes one collection."
        case .advancedOrganization: "Renaming, hiding and reordering are part of Pro."
        case .reminders: "Programme reminders are part of Pro."
        }
    }
}

private struct FeatureLine: View {
    let title: LocalizedStringKey

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "pawprint.fill")
                .foregroundStyle(Color.accent)
                .accessibilityHidden(true)
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Settings section: Pro status and a way to buy or restore.
struct ProSettingsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Section {
            if app.pro.isPro {
                Label(app.pro.hasPurchased ? "Seyrileo Pro is active" : "Seyrileo Pro (development build)", systemImage: "checkmark.seal.fill")
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button {
                    app.pro.paywall = .multipleSources
                } label: {
                    Label("Get Seyrileo Pro", systemImage: "sparkles")
                }
                Button("Restore purchase") { Task { await app.pro.restore() } }
            }
        } header: {
            Text(verbatim: "Seyrileo Pro")
        }
    }
}

/// Shows the paywall from the topmost registered presenter (root, a sheet, the player), the same
/// way the parental PIN prompt does: SwiftUI cannot present from the root while a sheet is open.
private struct ProPaywallPresenter: ViewModifier {
    @Environment(AppModel.self) private var app
    @State private var id = UUID()

    func body(content: Content) -> some View {
        let pro = app.pro
        content
            .onAppear { pro.register(id) }
            .onDisappear { pro.unregister(id) }
            .sheet(isPresented: Binding(
                get: { pro.paywall != nil && pro.presenters.last == id },
                set: { if !$0 { pro.paywall = nil } }
            )) {
                PaywallView(reason: pro.paywall)
            }
    }
}

extension View {
    func proPaywall() -> some View { modifier(ProPaywallPresenter()) }
}
