import Foundation
import Observation
import SeyrileoKit
import StoreKit

/// Seyrileo Pro: one non-consumable product, StoreKit 2. The entitlement is read from
/// `Transaction.currentEntitlements` (verified transactions only) and kept current by listening
/// to `Transaction.updates`. No server, no account; purchases follow the Apple ID.
///
/// DEBUG builds treat Pro as unlocked so the owner's device testing is not interrupted;
/// `-SeyrileoFreeTier` turns that off to test the free tier and the paywall.
///
/// Owner decision (2026-10-25): version 1 ships free, without Pro. While `isOffered` is false
/// everything is unlocked, StoreKit is never contacted and no Pro UI is shown.
@MainActor
@Observable
final class ProStore {
    /// Placeholder until the owner creates the product in App Store Connect (see docs/RELEASE.md).
    static let productID = "com.msy.seyrileo.pro"
    /// Flip to true (and set the real product ID) to sell Pro again.
    static let isOffered = false

    enum PurchaseState: Equatable {
        case idle, purchasing, pending, failed(String)
    }

    private(set) var product: Product?
    private(set) var hasPurchased = false
    private(set) var purchaseState: PurchaseState = .idle
    private(set) var productsUnavailable = false
    /// The feature that opened the paywall (for its headline), nil when closed.
    var paywall: ProFeature?
    /// Views that can present the paywall; the last one is in front.
    private(set) var presenters: [UUID] = []

    func register(_ id: UUID) { presenters.append(id) }
    func unregister(_ id: UUID) { presenters.removeAll { $0 == id } }

    @ObservationIgnored private var updates: Task<Void, Never>?
    @ObservationIgnored private let debugUnlocked: Bool

    init() {
        #if DEBUG
        debugUnlocked = !Self.isOffered || !ProcessInfo.processInfo.arguments.contains("-SeyrileoFreeTier")
        #else
        debugUnlocked = false
        #endif
    }

    var isPro: Bool { !Self.isOffered || hasPurchased || debugUnlocked }

    func start() async {
        guard Self.isOffered, updates == nil else { return }
        updates = Task { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let transaction) = update {
                    await transaction.finish()
                    await self?.refreshEntitlement()
                }
            }
        }
        await refreshEntitlement()
        await loadProduct()
    }

    func loadProduct() async {
        do {
            product = try await Product.products(for: [Self.productID]).first
            productsUnavailable = product == nil
        } catch {
            productsUnavailable = true
        }
    }

    func refreshEntitlement() async {
        var owned = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result, transaction.productID == Self.productID,
               transaction.revocationDate == nil {
                owned = true
            }
        }
        hasPurchased = owned
    }

    func purchase() async {
        guard let product else { return }
        purchaseState = .purchasing
        do {
            switch try await product.purchase() {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                    await refreshEntitlement()
                    purchaseState = .idle
                    if hasPurchased { paywall = nil }
                } else {
                    purchaseState = .failed(String(app: "The App Store could not verify the purchase."))
                }
            case .pending:
                purchaseState = .pending
            case .userCancelled:
                purchaseState = .idle
            @unknown default:
                purchaseState = .idle
            }
        } catch {
            purchaseState = .failed(String(app: "The purchase could not be completed. Nothing was charged."))
        }
    }

    func restore() async {
        purchaseState = .purchasing
        try? await AppStore.sync()
        await refreshEntitlement()
        purchaseState = .idle
        if hasPurchased { paywall = nil }
    }

    /// Returns true when allowed; otherwise opens the paywall for `feature`.
    func require(_ allowed: Bool, for feature: ProFeature) -> Bool {
        if allowed { return true }
        paywall = feature
        return false
    }
}
