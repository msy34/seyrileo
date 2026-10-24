import Foundation

/// What Seyrileo Pro unlocks (product contract): more than one source, more than one collection,
/// advanced organization (local names, hiding, personal order) and programme reminders.
/// Everything else — playback, guide, favorites, search, parental controls, accessibility,
/// diagnostics — is free. Losing Pro never deletes data: existing collections, names, hidden
/// items and reminders keep working; only new ones need Pro.
public enum ProFeature: String, CaseIterable, Sendable {
    case multipleSources
    case unlimitedCollections
    case advancedOrganization
    case reminders
}

public enum ProPolicy {
    public static let freeSourceLimit = 1
    public static let freeCollectionLimit = 1

    /// Whether adding one more provider source is allowed. The on-device sample does not count.
    public static func canAddSource(existingRealSources: Int, isPro: Bool) -> Bool {
        isPro || existingRealSources < freeSourceLimit
    }

    public static func canCreateCollection(existing: Int, isPro: Bool) -> Bool {
        isPro || existing < freeCollectionLimit
    }

    /// Features without a count: allowed with Pro only.
    public static func allows(_ feature: ProFeature, isPro: Bool) -> Bool {
        switch feature {
        case .multipleSources, .unlimitedCollections: true  // counted, see the functions above
        case .advancedOrganization, .reminders: isPro
        }
    }
}
