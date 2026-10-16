import Foundation
import Observation

/// Owns the single active playback session.
///
/// Invariants (covered by tests):
/// - At most one engine exists at a time; the previous engine is stopped before a new one
///   is created (protects one-connection subscriptions).
/// - Events from a superseded attempt are ignored.
/// - Transient failures get a bounded number of retries with backoff; no infinite loops.
/// - An unsupported-format failure tries at most one alternate engine, after stopping the first.
/// - An attempt that neither plays nor fails within `startupTimeout` is stopped and reported,
///   because some undecodable streams make AVPlayer wait silently forever.
@MainActor
@Observable
public final class PlaybackCoordinator {
    public private(set) var state: PlaybackState = .idle
    public private(set) var currentItem: PlaybackItem?
    public private(set) var engine: PlaybackEngine?
    public private(set) var events: [DiagnosticEvent] = []

    /// Called once per `play(_:)` when the first frame actually plays (not on retries or on
    /// resume after pause). Used to record "recently watched" honestly.
    @ObservationIgnored public var onPlaybackStarted: ((PlaybackItem) -> Void)?
    /// On-demand position updates: periodic, plus a final one when the item is stopped or
    /// replaced (so progress is saved even if the player closes between ticks).
    @ObservationIgnored public var onProgress: ((PlaybackItem, TimeInterval, TimeInterval?) -> Void)?
    /// Called when an on-demand item plays to its end.
    @ObservationIgnored public var onEnded: ((PlaybackItem) -> Void)?
    @ObservationIgnored private var lastProgress: (position: TimeInterval, duration: TimeInterval?)?

    /// false keeps playback on this device even if an AirPlay route is selected (used when a
    /// receiver cannot load the stream). Reset to true when the session ends.
    public var allowsExternalPlayback = true {
        didSet { engine?.setExternalPlaybackAllowed(allowsExternalPlayback) }
    }
    @ObservationIgnored private var reportedStart = false
    @ObservationIgnored private let factories: [PlaybackEngineFactory]
    @ObservationIgnored private let maxRetries: Int
    @ObservationIgnored private let retryPolicy: RetryPolicy
    @ObservationIgnored private let sleeper: Sleeper
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var attemptToken = 0
    @ObservationIgnored private var retryCount = 0
    /// Index into `engineOrder` of the engine currently in use.
    @ObservationIgnored private var factoryIndex = 0
    /// Engine order for the current item: primary first, or the alternate first when the
    /// item asks for it. At most one switch happens per play.
    @ObservationIgnored private var engineOrder: [Int] = [0]
    @ObservationIgnored private var nextEventID = 0
    @ObservationIgnored private let startupTimeout: Duration?
    @ObservationIgnored private var hasStartedPlaying = false
    @ObservationIgnored var pendingRetry: Task<Void, Never>?
    @ObservationIgnored var startupWatchdog: Task<Void, Never>?
    @ObservationIgnored private let maxEvents = 200

    public init(
        factories: [PlaybackEngineFactory], maxRetries: Int = 2,
        retryPolicy: RetryPolicy = RetryPolicy(baseDelay: .seconds(1), maxDelay: .seconds(4)),
        startupTimeout: Duration? = .seconds(20),
        sleeper: @escaping Sleeper = RetryPolicy.taskSleeper, now: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(!factories.isEmpty, "At least one playback engine is required")
        self.factories = Array(factories.prefix(2))  // primary + at most one alternate
        self.maxRetries = maxRetries
        self.retryPolicy = retryPolicy
        self.startupTimeout = startupTimeout
        self.sleeper = sleeper
        self.now = now
    }

    public var capabilities: EngineCapabilities? { engine?.capabilities }

    static func order(for item: PlaybackItem, engineCount: Int) -> [Int] {
        guard engineCount > 1 else { return [0] }
        return item.prefersAlternateEngine ? [1, 0] : [0, 1]
    }

    /// Starts `item`, first releasing whatever was playing.
    public func play(_ item: PlaybackItem) {
        reportFinalProgress()
        teardown()
        lastProgress = nil
        currentItem = item
        retryCount = 0
        factoryIndex = 0
        reportedStart = false
        engineOrder = Self.order(for: item, engineCount: factories.count)
        log("Play \(item.title) via \(factories[engineOrder[0]].engineName) — \(Redactor.describe(item.url))")
        startAttempt()
    }

    /// User-initiated retry after a failure: resets the automatic retry budget.
    public func retry() {
        guard let item = currentItem else { return }
        teardown()
        currentItem = item
        retryCount = 0
        factoryIndex = 0
        log("Manual retry")
        startAttempt()
    }

    public func pause() { engine?.pause() }
    public func resume() { engine?.play() }

    /// Stops playback and releases the stream.
    public func stop() {
        guard currentItem != nil || engine != nil else { return }
        reportFinalProgress()
        log("Stop")
        teardown()
        currentItem = nil
        state = .idle
        allowsExternalPlayback = true
    }

    // MARK: - Internals

    private func reportFinalProgress() {
        guard let item = currentItem, !item.isLive, hasStartedPlaying || lastProgress != nil else { return }
        if let progress = engine?.currentProgress() ?? lastProgress {
            lastProgress = progress
            onProgress?(item, progress.position, progress.duration)
        }
    }

    private func teardown() {
        attemptToken += 1
        pendingRetry?.cancel()
        pendingRetry = nil
        startupWatchdog?.cancel()
        startupWatchdog = nil
        if let engine {
            engine.onEvent = nil
            engine.stop()
        }
        engine = nil
    }

    private func startAttempt() {
        guard let current = currentItem else { return }
        precondition(engine == nil, "Previous engine must be released first")
        attemptToken += 1
        let token = attemptToken
        let newEngine = factories[engineOrder[factoryIndex]].makeEngine()
        // A retry or alternate engine continues from the last known position, not the start.
        let item = lastProgress.map { current.starting(at: $0.position) } ?? current
        newEngine.onEvent = { [weak self] event in
            self?.handle(event, token: token)
        }
        engine = newEngine
        newEngine.setExternalPlaybackAllowed(allowsExternalPlayback)
        state = .loading
        hasStartedPlaying = false
        newEngine.load(item)
        newEngine.play()
        armStartupWatchdog(token: token)
    }

    private func armStartupWatchdog(token: Int) {
        guard let startupTimeout else { return }
        startupWatchdog = Task { [weak self, sleeper] in
            do { try await sleeper(startupTimeout) } catch { return }
            guard let self, token == self.attemptToken, !self.hasStartedPlaying else { return }
            self.startupWatchdog = nil
            self.log("No playback within \(startupTimeout)")
            self.handleFailure(.startupTimedOut)
        }
    }

    private func handle(_ event: EngineEvent, token: Int) {
        guard token == attemptToken else { return }  // stale attempt
        switch event {
        case .readyToPlay:
            log("Ready")
        case .playing:
            if state != .playing { log("Playing") }
            state = .playing
            retryCount = 0
            hasStartedPlaying = true
            startupWatchdog?.cancel()
            startupWatchdog = nil
            if !reportedStart, let item = currentItem {
                reportedStart = true
                onPlaybackStarted?(item)
            }
        case .paused:
            state = .paused
        case .buffering:
            if state != .buffering { log("Buffering") }
            state = .buffering
        case .ended:
            log("Ended")
            if let item = currentItem, !item.isLive {
                if let duration = lastProgress?.duration ?? engine?.currentProgress()?.duration {
                    lastProgress = (duration, duration)
                    onProgress?(item, duration, duration)
                }
                state = .ended
                onEnded?(item)
            } else {
                state = .ended
            }
        case .note(let message):
            log(message)
        case .progress(let position, let duration):
            guard let item = currentItem, !item.isLive else { return }
            lastProgress = (position, duration)
            onProgress?(item, position, duration)
        case .failed(let failure):
            handleFailure(failure)
        }
    }

    private func handleFailure(_ failure: PlaybackFailure) {
        log("Failure: \(failure)")
        if failure.isTransient && retryCount < maxRetries {
            retryCount += 1
            let attempt = retryCount
            let delay = retryPolicy.delay(beforeRetry: attempt)
            teardown()
            state = .retrying(attempt: attempt, of: maxRetries)
            log("Retry \(attempt)/\(maxRetries) in \(delay)")
            let token = attemptToken
            pendingRetry = Task { [weak self, sleeper] in
                do { try await sleeper(delay) } catch { return }
                guard let self, token == self.attemptToken else { return }
                self.pendingRetry = nil
                self.startAttempt()
            }
            return
        }
        if failure.mayBenefitFromAlternateEngine && factoryIndex + 1 < engineOrder.count {
            teardown()
            factoryIndex += 1
            log("Trying alternate engine \(factories[engineOrder[factoryIndex]].engineName)")
            startAttempt()
            return
        }
        teardown()
        state = .failed(failure)
    }

    private func log(_ message: String) {
        let text = currentItem?.redactor.redact(message) ?? Redactor().redact(message)
        events.append(DiagnosticEvent(id: nextEventID, date: now(), message: text))
        nextEventID += 1
        if events.count > maxEvents { events.removeFirst(events.count - maxEvents) }
    }
}
