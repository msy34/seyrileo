import AVFoundation
import Foundation
import Testing
@testable import SeyrileoFixtureServer
@testable import SeyrileoKit

/// Remembered audio/subtitle choice in the built-in player, against a fixture MP4 with English and
/// Turkish audio and subtitles. Names saved from VLC ("Track 2 - [Turkish]") must match too.
@MainActor
@Suite(.serialized) struct AVPlayerTrackPreferenceTests {
    func movie(_ preference: TrackPreference?) async throws -> (AVPlayerEngine, FixtureServer, AsyncStream<EngineEvent>) {
        let server = try FixtureServer(port: 0)
        try await server.start()
        let base = try #require(server.baseURL)
        let credentials = XtreamCredentials(username: FixtureServer.username, password: FixtureServer.password)
        let url = try XtreamEndpoint(baseURL: base).movieStreamURL(credentials: credentials, streamID: "304", containerExtension: "mp4")
        let item = PlaybackItem(
            id: MediaKey(providerID: UUID(), kind: .movie, remoteID: "304"), title: "Languages", sourceName: "fixture",
            url: url, isLive: false, redactor: Redactor(secrets: credentials.secrets), trackPreference: preference)
        let engine = AVPlayerEngine()
        let (stream, continuation) = AsyncStream<EngineEvent>.makeStream()
        engine.onEvent = { continuation.yield($0) }
        engine.load(item)
        engine.play()
        return (engine, server, stream)
    }

    /// First matching event, or nil after 20 s (a bound for a stuck player, not a sleep).
    nonisolated func waitFor(_ stream: AsyncStream<EngineEvent>, _ match: @escaping @Sendable (EngineEvent) -> Bool) async -> EngineEvent? {
        await withTaskGroup(of: EngineEvent?.self) { group in
            group.addTask {
                for await event in stream where match(event) { return event }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(20))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    func selected(_ engine: AVPlayerEngine, _ characteristic: AVMediaCharacteristic) async throws -> String? {
        let item = try #require(engine.player.currentItem)
        let group = try #require(try await item.asset.loadMediaSelectionGroup(for: characteristic))
        return item.currentMediaSelection.selectedMediaOption(in: group)?.extendedLanguageTag
    }

    @Test func rememberedVLCNamesSelectTurkishAudioAndSubtitles() async throws {
        let (engine, server, events) = try await movie(TrackPreference(audio: "Track 2 - [Turkish]", subtitle: "Türkçe - [Turkish]"))
        defer { engine.stop(); server.stop() }
        let applied = await waitFor(events) { if case .note(let text) = $0 { text.contains("remembered") } else { false } }
        #expect(applied != nil)
        #expect(try await selected(engine, .audible) == "tr")
        #expect(try await selected(engine, .legible) == "tr")
    }

    @Test func userChangeIsReportedWithEnglishNames() async throws {
        let (engine, server, events) = try await movie(nil)
        defer { engine.stop(); server.stop() }
        _ = await waitFor(events) { $0 == .playing }
        try await Task.sleep(for: .seconds(1.5))  // past the initial-selection window
        let item = try #require(engine.player.currentItem)
        let audio = try #require(try await item.asset.loadMediaSelectionGroup(for: .audible))
        // AVPlayer's default follows the device language, so switch to whichever is not selected.
        let current = item.currentMediaSelection.selectedMediaOption(in: audio)
        let other = try #require(audio.options.first { $0 != current })
        let expected = other.displayName(with: Locale(identifier: "en"))
        item.select(other, in: audio)  // what AVKit's audio menu does
        let chosen = await waitFor(events) { if case .tracksChosen = $0 { true } else { false } }
        guard case .tracksChosen(let preference)? = chosen else { Issue.record("no choice reported"); return }
        #expect(preference.audio == expected)
        #expect(preference.subtitlesOff == (preference.subtitle == nil))
    }
}
