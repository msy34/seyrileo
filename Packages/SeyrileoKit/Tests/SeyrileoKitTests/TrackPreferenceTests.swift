import Foundation
import Testing
@testable import SeyrileoKit

@Suite struct TrackPreferenceTests {
    let episode1: [(index: Int32, name: String)] = [(-1, "Disable"), (1, "Track 1 - [Turkish]"), (2, "Track 2 - [English]")]
    // The next episode numbers its tracks differently.
    let episode2: [(index: Int32, name: String)] = [(-1, "Disable"), (3, "Track 1 - [English]"), (4, "Track 2 - [Turkish]")]

    @Test func sameNameWins() {
        #expect(TrackMatcher.bestMatch("Track 2 - [English]", among: episode1) == 2)
    }

    @Test func sameLanguageAcrossEpisodes() {
        #expect(TrackMatcher.bestMatch("Track 2 - [English]", among: episode2) == 3)
        #expect(TrackMatcher.bestMatch("Track 1 - [Turkish]", among: episode2) == 4)
    }

    @Test func turkishCaseAndPlainNames() {
        let tracks: [(index: Int32, name: String)] = [(5, "Türkçe"), (6, "İngilizce")]
        #expect(TrackMatcher.bestMatch("TÜRKÇE", among: tracks) == 5)
        #expect(TrackMatcher.bestMatch("Altyazı - [Türkçe]", among: tracks) == 5)
    }

    @Test func noMatchKeepsDefaultAndNeverPicksDisable() {
        #expect(TrackMatcher.bestMatch("Track 9 - [German]", among: episode1) == nil)
        #expect(TrackMatcher.bestMatch("Disable", among: episode1) == nil)
    }

    @Test func keysAndCoding() throws {
        let key = MediaKey(providerID: UUID(), kind: .series, remoteID: "401")
        #expect(TrackPreference.storageKey(for: key) == "tracks|series|401")
        let preference = TrackPreference(audio: "Track 2 - [English]", subtitle: "Track 3 - [Turkish]")
        let decoded = try JSONDecoder().decode(TrackPreference.self, from: JSONEncoder().encode(preference))
        #expect(decoded == preference)
    }
}
