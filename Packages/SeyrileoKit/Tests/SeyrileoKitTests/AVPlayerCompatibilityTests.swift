import Foundation
import Testing
@testable import SeyrileoFixtureServer
@testable import SeyrileoKit

/// Real AVPlayer against the loopback fixture server. Records what the built-in engine does
/// with each scenario; results feed docs/COMPATIBILITY.md. Simulator/macOS results are not
/// physical-device results.
@MainActor
@Suite(.serialized) struct AVPlayerCompatibilityTests {
    enum Outcome: Equatable {
        case playing
        case failed(PlaybackFailure)
        case timedOut
    }

    /// Waits for the first terminal engine event. The timeout is a bound for a stuck
    /// network, not a correctness mechanism: success returns as soon as `.playing` arrives.
    func outcome(for channel: FixtureServer.Channel, format: StreamFormat, timeout: Duration = .seconds(20)) async throws -> (Outcome, [String]) {
        let server = try FixtureServer(port: 0)
        try await server.start()
        defer { server.stop() }
        let base = try #require(server.baseURL)
        let credentials = XtreamCredentials(username: FixtureServer.username, password: FixtureServer.password)
        let url = try XtreamEndpoint(baseURL: base).liveStreamURL(credentials: credentials, streamID: channel.rawValue, format: format)
        let item = PlaybackItem(
            id: MediaKey(providerID: UUID(), kind: .live, remoteID: channel.rawValue), title: channel.rawValue,
            sourceName: "fixture", url: url, isLive: true, redactor: Redactor(secrets: credentials.secrets))

        let engine = AVPlayerEngine()
        var notes: [String] = []
        let result: Outcome = await withCheckedContinuation { continuation in
            var finished = false
            let finish: (Outcome) -> Void = { outcome in
                guard !finished else { return }
                finished = true
                continuation.resume(returning: outcome)
            }
            engine.onEvent = { event in
                switch event {
                case .playing: finish(.playing)
                case .failed(let failure): finish(.failed(failure))
                case .note(let note): notes.append(note)
                default: break
                }
            }
            engine.load(item)
            engine.play()
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                finish(.timedOut)
            }
        }
        engine.stop()
        let log = notes.joined(separator: "\n")
        #expect(!log.contains(FixtureServer.username))
        #expect(!log.contains("/live/"))
        return (result, notes)
    }

    @Test func liveHLSPlays() async throws {
        let (result, notes) = try await outcome(for: .patternA, format: .hls)
        #expect(result == .playing, "\(notes)")
    }

    @Test func notFoundIsClassified() async throws {
        let (result, notes) = try await outcome(for: .offline, format: .hls)
        print("[matrix] 404 → \(result) \(notes)")
        #expect(result == .failed(.streamNotFound), "\(notes)")
    }

    @Test func forbiddenIsClassified() async throws {
        let (result, notes) = try await outcome(for: .forbidden, format: .hls)
        print("[matrix] 403 → \(result) \(notes)")
        #expect(result == .failed(.accessDenied(httpStatus: nil)), "\(notes)")
    }

    /// Finite MPEG-TS file served with Content-Length and byte ranges (Xtream ".ts" request
    /// for a channel whose fixture answers with a file).
    @Test func rawMPEGTSFileWithRangesOutcome() async throws {
        let (result, notes) = try await outcome(for: .patternA, format: .mpegts, timeout: .seconds(10))
        print("[matrix] raw TS file + ranges → \(result) \(notes)")
        #expect(result != .timedOut, "\(notes)")
    }

    /// Live-style raw MPEG-TS: no Content-Length, no ranges (typical Xtream ".ts" output).
    @Test func liveRawMPEGTSOutcome() async throws {
        let (result, notes) = try await outcome(for: .mpegTSOnly, format: .mpegts, timeout: .seconds(10))
        print("[matrix] live raw TS (no length/ranges) → \(result) \(notes)")
        #expect(result != .timedOut, "\(notes)")
    }

    /// Provider answers an ".m3u8" request with a raw TS body (seen with TS-only providers).
    @Test func tsBodyOnHLSURLOutcome() async throws {
        let (result, notes) = try await outcome(for: .mpegTSOnly, format: .hls, timeout: .seconds(10))
        print("[matrix] TS body on .m3u8 URL → \(result) \(notes)")
        #expect(result != .playing)
        #expect(result != .timedOut, "\(notes)")
    }

    @Test func hlsWithMP2AudioFailsInAVPlayer() async throws {
        let (result, notes) = try await outcome(for: .mp2Audio, format: .hls, timeout: .seconds(10))
        print("[matrix] HLS + MP2 audio → \(result) \(notes)")
        #if os(iOS)
        // iOS has no MPEG-1 Layer II decoder (macOS does, so there it plays).
        #expect(result == .failed(.unsupportedFormat), "\(notes)")
        #else
        #expect(result != .timedOut, "\(notes)")
        #endif
    }

    /// Observed: AVPlayer reports nothing for undecodable HLS segments and keeps waiting.
    /// The coordinator's startup watchdog exists for exactly this case.
    @Test func corruptMediaNeverPlays() async throws {
        let (result, notes) = try await outcome(for: .corrupt, format: .hls, timeout: .seconds(8))
        print("[matrix] corrupt → \(result) \(notes)")
        #expect(result != .playing)
    }
}

/// Real AVPlayer with on-demand fixtures: progressive MP4 with byte ranges, resume seek, MKV.
@MainActor
@Suite(.serialized) struct AVPlayerOnDemandTests {
    func play(_ path: String, start: TimeInterval, until predicate: @escaping (EngineEvent, AVPlayerEngine) -> Bool,
              timeout: Duration = .seconds(20)) async throws -> (EngineEvent?, (position: TimeInterval, duration: TimeInterval?)?) {
        let server = try FixtureServer(port: 0)
        try await server.start()
        defer { server.stop() }
        let base = try #require(server.baseURL)
        let endpoint = try XtreamEndpoint(baseURL: base)
        let credentials = XtreamCredentials(username: FixtureServer.username, password: FixtureServer.password)
        let parts = path.split(separator: "/")
        let url = parts[0] == "movie"
            ? endpoint.movieStreamURL(credentials: credentials, streamID: String(parts[1].split(separator: ".")[0]), containerExtension: String(parts[1].split(separator: ".")[1]))
            : endpoint.episodeStreamURL(credentials: credentials, episodeID: String(parts[1].split(separator: ".")[0]), containerExtension: String(parts[1].split(separator: ".")[1]))
        let item = PlaybackItem(
            id: MediaKey(providerID: UUID(), kind: .movie, remoteID: "x"), title: "x", sourceName: "fixture", url: url,
            isLive: false, redactor: Redactor(secrets: credentials.secrets), startPosition: start)
        let engine = AVPlayerEngine()
        var progressAtFinish: (position: TimeInterval, duration: TimeInterval?)?
        let result: EngineEvent? = await withCheckedContinuation { continuation in
            var finished = false
            let finish: (EngineEvent?) -> Void = { event in
                guard !finished else { return }
                finished = true
                progressAtFinish = engine.currentProgress()
                continuation.resume(returning: event)
            }
            engine.onEvent = { event in
                if case .failed = event { finish(event) } else if predicate(event, engine) { finish(event) }
            }
            engine.load(item)
            engine.play()
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                finish(nil)
            }
        }
        engine.stop()
        return (result, progressAtFinish)
    }

    @Test func progressiveMP4PlaysAndResumesAtSavedPosition() async throws {
        let (event, progress) = try await play("movie/301.mp4", start: 120) { event, engine in
            if case .playing = event { return (engine.currentProgress()?.position ?? 0) >= 114 }
            if case .progress = event { return (engine.currentProgress()?.position ?? 0) >= 114 }
            return false
        }
        print("[matrix] MP4 resume → \(String(describing: event)) at \(String(describing: progress))")
        #expect(event != nil, "did not reach the resume position")
        // Keyframe-tolerant resume: may land up to 5 s early, never later.
        #expect((progress?.position ?? 0) >= 114 && (progress?.position ?? 0) <= 121)
        #expect(abs((progress?.duration ?? 0) - 180) < 1)
    }

    @Test func mkvOutcomeIsRecorded() async throws {
        let (event, _) = try await play("movie/302.mkv", start: 0, until: { event, _ in event == .playing }, timeout: .seconds(10))
        print("[matrix] MKV → \(String(describing: event))")
        #expect(event != nil, "MKV neither played nor failed within 10 s")
    }
}
