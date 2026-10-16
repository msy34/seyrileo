import Foundation
import Testing
@testable import SeyrileoKit

/// Tracks how many fake engines are alive (loaded and not stopped) at once.
@MainActor
final class EngineLedger {
    var created: [FakeEngine] = []
    var maxSimultaneous = 0
    var active: Int { created.filter { $0.isLoaded && !$0.isStopped }.count }
}

@MainActor
final class FakeEngine: PlaybackEngine {
    let ledger: EngineLedger
    let capabilities: EngineCapabilities
    var onEvent: ((EngineEvent) -> Void)?
    private(set) var isLoaded = false
    private(set) var isStopped = false
    private(set) var loadedItem: PlaybackItem?

    init(name: String, ledger: EngineLedger) {
        self.ledger = ledger
        capabilities = EngineCapabilities(
            engineName: name, hls: .verified, liveMPEGTS: .unsupported, pictureInPicture: .notEnabled,
            airPlay: .unverified, trackSelection: .unverified)
    }

    func load(_ item: PlaybackItem) {
        isLoaded = true
        loadedItem = item
        ledger.maxSimultaneous = max(ledger.maxSimultaneous, ledger.active)
    }

    var progress: (position: TimeInterval, duration: TimeInterval?)?

    func play() {}
    func pause() { onEvent?(.paused) }
    func currentProgress() -> (position: TimeInterval, duration: TimeInterval?)? { progress }
    private(set) var externalPlaybackAllowed = true
    func setExternalPlaybackAllowed(_ allowed: Bool) { externalPlaybackAllowed = allowed }
    func stop() { isStopped = true }

    /// Emits even after stop, simulating late callbacks from a real engine.
    func emitLate(_ event: EngineEvent) { onEvent?(event) }
}

@MainActor
struct FakeFactory: PlaybackEngineFactory {
    let engineName: String
    let ledger: EngineLedger
    func makeEngine() -> PlaybackEngine {
        let engine = FakeEngine(name: engineName, ledger: ledger)
        ledger.created.append(engine)
        return engine
    }
}

@MainActor
@Suite struct PlaybackCoordinatorTests {
    let ledger = EngineLedger()

    func makeCoordinator(
        alternate: Bool = false, startupTimeout: Duration? = nil, sleeper: @escaping Sleeper = { _ in }
    ) -> PlaybackCoordinator {
        var factories: [PlaybackEngineFactory] = [FakeFactory(engineName: "primary", ledger: ledger)]
        if alternate { factories.append(FakeFactory(engineName: "alternate", ledger: ledger)) }
        return PlaybackCoordinator(factories: factories, maxRetries: 2, startupTimeout: startupTimeout, sleeper: sleeper)
    }

    static func item(_ id: String, secret: String = "s3cret-pw") -> PlaybackItem {
        PlaybackItem(
            id: MediaKey(providerID: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!, kind: .live, remoteID: id),
            title: "Channel \(id)", sourceName: "Test",
            url: URL(string: "http://tv.example.com/live/user/\(secret)/\(id).m3u8")!, isLive: true,
            redactor: Redactor(secrets: ["user", secret]))
    }

    var engines: [FakeEngine] { ledger.created }

    @Test func switchingChannelsStopsPreviousBeforeOpeningNext() {
        let coordinator = makeCoordinator()
        for index in 0..<100 {
            coordinator.play(Self.item("\(index)"))
            engines.last?.emitLate(.playing)
        }
        #expect(engines.count == 100)
        #expect(ledger.maxSimultaneous == 1)
        #expect(ledger.active == 1)
        #expect(engines.dropLast().allSatisfy { $0.isStopped })
        #expect(coordinator.state == .playing)
        coordinator.stop()
        #expect(ledger.active == 0)
        #expect(coordinator.state == .idle)
        #expect(coordinator.engine == nil)
        #expect(coordinator.currentItem == nil)
    }

    @Test func staleEventsFromPreviousEngineAreIgnored() {
        let coordinator = makeCoordinator()
        coordinator.play(Self.item("1"))
        let first = engines[0]
        coordinator.play(Self.item("2"))
        first.emitLate(.failed(.streamNotFound))
        first.emitLate(.playing)
        #expect(coordinator.state == .loading)
        #expect(coordinator.currentItem?.id.remoteID == "2")
    }

    @Test func transientFailureRetriesBoundedThenFails() async {
        let sleeper = RecordingSleeper()
        let coordinator = makeCoordinator(sleeper: sleeper.sleeper)
        coordinator.play(Self.item("1"))
        engines.last?.emitLate(.failed(.timedOut))
        #expect(coordinator.state == .retrying(attempt: 1, of: 2))
        await coordinator.pendingRetry?.value
        #expect(engines.count == 2)
        engines.last?.emitLate(.failed(.timedOut))
        #expect(coordinator.state == .retrying(attempt: 2, of: 2))
        await coordinator.pendingRetry?.value
        engines.last?.emitLate(.failed(.timedOut))
        #expect(coordinator.state == .failed(.timedOut))
        #expect(engines.count == 3)
        #expect(ledger.maxSimultaneous == 1)
        #expect(ledger.active == 0)
        #expect(sleeper.recorded == [.seconds(1), .seconds(2)])
    }

    @Test func successResetsRetryBudget() async {
        let coordinator = makeCoordinator()
        coordinator.play(Self.item("1"))
        engines.last?.emitLate(.failed(.timedOut))
        await coordinator.pendingRetry?.value
        engines.last?.emitLate(.playing)
        engines.last?.emitLate(.failed(.timedOut))
        #expect(coordinator.state == .retrying(attempt: 1, of: 2))
    }

    @Test(arguments: [
        PlaybackFailure.streamNotFound, .accessDenied(httpStatus: 403), .accessDenied(httpStatus: nil),
        .insecureConnectionBlocked, .offline, .unsupportedFormat, .unknown(nil),
    ])
    func nonTransientFailuresAreNotRetried(failure: PlaybackFailure) {
        let coordinator = makeCoordinator()
        coordinator.play(Self.item("1"))
        engines.last?.emitLate(.failed(failure))
        #expect(coordinator.state == .failed(failure))
        #expect(engines.count == 1)
        #expect(ledger.active == 0)
    }

    @Test func unsupportedFormatTriesOneAlternateEngineAfterStoppingFirst() {
        let coordinator = makeCoordinator(alternate: true)
        coordinator.play(Self.item("1"))
        engines[0].emitLate(.failed(.unsupportedFormat))
        #expect(engines.count == 2)
        #expect(engines[0].isStopped)
        #expect(engines[1].capabilities.engineName == "alternate")
        #expect(ledger.maxSimultaneous == 1)
        engines[1].emitLate(.failed(.unsupportedFormat))
        #expect(engines.count == 2)
        #expect(coordinator.state == .failed(.unsupportedFormat))
    }

    @Test func silentEngineIsStoppedByStartupWatchdog() async {
        let coordinator = makeCoordinator(startupTimeout: .seconds(20))
        coordinator.play(Self.item("1"))
        engines.last?.emitLate(.buffering)
        await coordinator.startupWatchdog?.value
        #expect(coordinator.state == .failed(.startupTimedOut))
        #expect(ledger.active == 0)
        #expect(engines.count == 1)
    }

    @Test func startupWatchdogTriesAlternateEngineOnce() async {
        let coordinator = makeCoordinator(alternate: true, startupTimeout: .seconds(20))
        coordinator.play(Self.item("1"))
        await coordinator.startupWatchdog?.value
        #expect(engines.count == 2)
        #expect(engines[0].isStopped)
        await coordinator.startupWatchdog?.value
        #expect(coordinator.state == .failed(.startupTimedOut))
        #expect(ledger.maxSimultaneous == 1)
    }

    @Test func watchdogDoesNotFireAfterPlaybackStarts() async {
        let gate = AsyncGate()
        let coordinator = makeCoordinator(startupTimeout: .seconds(20), sleeper: { _ in await gate.wait() })
        coordinator.play(Self.item("1"))
        let watchdog = coordinator.startupWatchdog
        engines.last?.emitLate(.playing)
        await gate.open()
        await watchdog?.value
        #expect(coordinator.state == .playing)
    }

    @Test func playbackStartedIsReportedOncePerPlay() async {
        let coordinator = makeCoordinator()
        var started: [String] = []
        coordinator.onPlaybackStarted = { started.append($0.id.remoteID) }
        coordinator.play(Self.item("1"))
        engines.last?.emitLate(.buffering)
        #expect(started.isEmpty)  // loading is not "watched"
        engines.last?.emitLate(.playing)
        engines.last?.emitLate(.paused)
        engines.last?.emitLate(.playing)
        engines.last?.emitLate(.failed(.timedOut))
        await coordinator.pendingRetry?.value
        engines.last?.emitLate(.playing)
        coordinator.play(Self.item("2"))
        engines.last?.emitLate(.failed(.streamNotFound))
        #expect(started == ["1"])
    }

    @Test func preferredAlternateEngineStartsFirstAndFallsBackOnce() {
        let coordinator = makeCoordinator(alternate: true)
        let base = Self.item("1")
        let item = PlaybackItem(
            id: base.id, title: base.title, sourceName: base.sourceName, url: base.url, isLive: false,
            redactor: base.redactor, prefersAlternateEngine: true)
        coordinator.play(item)
        #expect(engines.map { $0.capabilities.engineName } == ["alternate"])
        engines[0].emitLate(.failed(.unsupportedFormat))
        #expect(engines.map { $0.capabilities.engineName } == ["alternate", "primary"])
        #expect(engines[0].isStopped)
        engines[1].emitLate(.failed(.unsupportedFormat))
        #expect(engines.count == 2)
        #expect(coordinator.state == .failed(.unsupportedFormat))
        #expect(ledger.maxSimultaneous == 1)
    }

    @Test func localOnlyPlaybackAppliesToRetriesAndResetsOnStop() {
        let coordinator = makeCoordinator()
        coordinator.play(Self.item("1"))
        #expect(engines[0].externalPlaybackAllowed)
        engines[0].emitLate(.failed(.accessDenied(httpStatus: nil)))
        coordinator.allowsExternalPlayback = false
        coordinator.retry()
        #expect(engines[1].externalPlaybackAllowed == false)
        #expect(ledger.maxSimultaneous == 1)
        coordinator.stop()
        #expect(coordinator.allowsExternalPlayback)
    }

    @Test func stopDuringRetryBackoffCancelsRetry() async {
        let coordinator = makeCoordinator()
        coordinator.play(Self.item("1"))
        engines.last?.emitLate(.failed(.timedOut))
        let pending = coordinator.pendingRetry
        coordinator.stop()
        await pending?.value
        #expect(engines.count == 1)
        #expect(coordinator.state == .idle)
    }

    @Test func manualRetryAfterFailureStartsFreshAttempt() {
        let coordinator = makeCoordinator()
        coordinator.play(Self.item("1"))
        engines.last?.emitLate(.failed(.streamNotFound))
        coordinator.retry()
        #expect(engines.count == 2)
        #expect(coordinator.state == .loading)
        #expect(ledger.active == 1)
    }

    @Test func diagnosticsLogNeverContainsSecrets() {
        let coordinator = makeCoordinator()
        coordinator.play(Self.item("1", secret: "hunter22"))
        engines.last?.emitLate(.note("Error loading http://tv.example.com/live/user/hunter22/1.m3u8 (hunter22)"))
        engines.last?.emitLate(.failed(.streamNotFound))
        let log = coordinator.events.map(\.message).joined(separator: "\n")
        #expect(!log.contains("hunter22"))
        #expect(!log.contains("/live/"))
        #expect(log.contains("http://tv.example.com/[redacted]"))
    }
}

@Suite struct AVPlayerEngineClassificationTests {
    let redactor = Redactor(secrets: ["pw-secret"])

    @Test func httpStatusFromErrorLogWins() {
        #expect(AVPlayerEngine.classify(error: nil, httpStatus: 404, redactor: redactor) == .streamNotFound)
        #expect(AVPlayerEngine.classify(error: nil, httpStatus: 403, redactor: redactor) == .accessDenied(httpStatus: 403))
        #expect(AVPlayerEngine.classify(error: nil, httpStatus: 503, redactor: redactor) == .serverError(httpStatus: 503))
    }

    @Test func urlErrorsInUnderlyingChain() {
        let ats = NSError(domain: NSURLErrorDomain, code: NSURLErrorAppTransportSecurityRequiresSecureConnection)
        let wrapped = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [NSUnderlyingErrorKey: ats])
        #expect(AVPlayerEngine.classify(error: wrapped, httpStatus: nil, redactor: redactor) == .insecureConnectionBlocked)
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        #expect(AVPlayerEngine.classify(error: offline, httpStatus: nil, redactor: redactor) == .offline)
    }

    @Test func unsupportedAudioDataFormatIsUnsupportedFormat() {
        // Observed: AVFoundation -11800 wrapping CoreMedia 1718449215 ('fmt?') for MP2 audio in HLS.
        #expect(AVPlayerEngine.unsupportedDataFormatStatus == 1_718_449_215)
        let core = NSError(domain: "CoreMediaErrorDomain", code: 1_718_449_215)
        #expect(AVPlayerEngine.classify(error: core, httpStatus: nil, redactor: redactor) == .unsupportedFormat)
        let wrapped = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [NSUnderlyingErrorKey: core])
        #expect(AVPlayerEngine.classify(error: wrapped, httpStatus: nil, redactor: redactor) == .unsupportedFormat)
    }

    @Test func nonPlaylistResponseIsUnsupportedFormat() {
        #expect(AVPlayerEngine.classify(error: NSError(domain: "CoreMediaErrorDomain", code: -12646), httpStatus: nil, redactor: redactor) == .unsupportedFormat)
    }

    @Test func alternateEngineIsTriedOnlyForFormatLikeFailures() {
        #expect(PlaybackFailure.unknown(nil).mayBenefitFromAlternateEngine)
        #expect(!PlaybackFailure.streamNotFound.mayBenefitFromAlternateEngine)
        #expect(!PlaybackFailure.accessDenied(httpStatus: nil).mayBenefitFromAlternateEngine)
        #expect(!PlaybackFailure.offline.mayBenefitFromAlternateEngine)
        #expect(!PlaybackFailure.insecureConnectionBlocked.mayBenefitFromAlternateEngine)
    }

    @Test func coreMediaATSRefusalIsInsecureConnection() {
        let error = NSError(domain: "CoreMediaErrorDomain", code: -1022)
        #expect(AVPlayerEngine.classify(error: error, httpStatus: nil, redactor: redactor) == .insecureConnectionBlocked)
    }

    @Test func failingURLIsFoundInChainAndReducedToOrigin() throws {
        let inner = NSError(domain: NSURLErrorDomain, code: -1022, userInfo: [
            NSURLErrorFailingURLStringErrorKey: "http://edge.example:8000/live/u/pw-secret/1.ts?token=x",
        ])
        let outer = NSError(domain: "CoreMediaErrorDomain", code: -1022, userInfo: [NSUnderlyingErrorKey: inner])
        let url = try #require(AVPlayerEngine.failingURL(in: outer))
        #expect(Redactor.describe(url) == "http://edge.example:8000/[redacted]")
    }

    @Test func formatErrors() {
        let error = NSError(domain: "AVFoundationErrorDomain", code: -11828)
        #expect(AVPlayerEngine.classify(error: error, httpStatus: nil, redactor: redactor) == .unsupportedFormat)
        let server = NSError(domain: "AVFoundationErrorDomain", code: -11850)
        #expect(AVPlayerEngine.classify(error: server, httpStatus: nil, redactor: redactor) == .serverIncompatible)
    }

    @Test func permissionErrorIsAccessDeniedWithoutInventedStatus() {
        // Observed from AVPlayer for an HLS playlist answered with HTTP 403.
        let underlying = NSError(domain: "CoreMediaErrorDomain", code: -12660)
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNoPermissionsToReadFile, userInfo: [NSUnderlyingErrorKey: underlying])
        #expect(AVPlayerEngine.classify(error: error, httpStatus: nil, redactor: redactor) == .accessDenied(httpStatus: nil))
    }

    @Test func unknownStaysUnknownAndSanitized() {
        let error = NSError(domain: "CoreMediaErrorDomain", code: -12345, userInfo: [
            NSLocalizedDescriptionKey: "failed http://x.example/live/u/pw-secret/1.ts",
        ])
        guard case .unknown(let sanitized?) = AVPlayerEngine.classify(error: error, httpStatus: 302, redactor: redactor) else {
            Issue.record("expected unknown")
            return
        }
        #expect(sanitized.identifier == "CoreMediaErrorDomain#-12345")
        #expect(!sanitized.message.contains("pw-secret"))
    }
}
