import Testing
@testable import SeyrileoKit

@Suite struct ProPolicyTests {
    @Test func freeTierLimits() {
        #expect(ProPolicy.canAddSource(existingRealSources: 0, isPro: false))
        #expect(!ProPolicy.canAddSource(existingRealSources: 1, isPro: false))
        #expect(ProPolicy.canAddSource(existingRealSources: 5, isPro: true))
        #expect(ProPolicy.canCreateCollection(existing: 0, isPro: false))
        #expect(!ProPolicy.canCreateCollection(existing: 1, isPro: false))
        #expect(ProPolicy.canCreateCollection(existing: 9, isPro: true))
    }

    @Test func proOnlyFeatures() {
        for feature in [ProFeature.advancedOrganization, .reminders] {
            #expect(!ProPolicy.allows(feature, isPro: false))
            #expect(ProPolicy.allows(feature, isPro: true))
        }
    }
}
