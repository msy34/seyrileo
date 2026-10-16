import AVFoundation
import Foundation

public struct AVPlayerEngineFactory: PlaybackEngineFactory {
    public init() {}
    public var engineName: String { AVPlayerEngine.name }
    public func makeEngine() -> PlaybackEngine { AVPlayerEngine() }
}

/// AVFoundation-backed engine: HLS and other formats AVFoundation natively supports.
/// Measured against the fixture server (see docs/COMPATIBILITY.md): live MPEG-TS without
/// Content-Length or byte ranges (typical Xtream ".ts" output) fails with -11850.
@MainActor
public final class AVPlayerEngine: PlaybackEngine {
    public static let name = "AVPlayer"

    public let player = AVPlayer()
    public var onEvent: ((EngineEvent) -> Void)?
    public let capabilities = EngineCapabilities(
        engineName: AVPlayerEngine.name,
        hls: .unverified,
        liveMPEGTS: .unsupported,
        pictureInPicture: .unverified,
        airPlay: .unverified,
        trackSelection: .unverified)

    private var item: AVPlayerItem?
    private var redactor = Redactor()
    private var observations: [NSKeyValueObservation] = []
    private var notificationTokens: [NSObjectProtocol] = []
    private var isStopped = false
    private var stallCount = 0
    private var isLive = true
    private var pendingStart: TimeInterval = 0
    /// While a resume seek is pending, `play()` is deferred: starting at 0 and then seeking
    /// would download the beginning of the file first.
    private var isSeekingToStart = false
    private var playRequested = false
    private var timeObserver: Any?

    public init() {
        player.automaticallyWaitsToMinimizeStalling = true
        // AirPlay video: hand the item to the receiver (it fetches the stream itself). During
        // Screen Mirroring the app instead draws the phone-decoded video on the external display
        // (some providers refuse the receiver's own request), so no automatic switch here.
        player.allowsExternalPlayback = true
        #if os(iOS) || os(tvOS)
        player.usesExternalPlaybackWhileExternalScreenIsActive = false
        #endif
    }

    public func load(_ item: PlaybackItem) {
        guard !isStopped else { return }
        redactor = item.redactor
        isLive = item.isLive
        pendingStart = item.startPosition
        isSeekingToStart = item.startPosition > 0
        let asset = AVURLAsset(url: item.url)
        let playerItem = AVPlayerItem(asset: asset)
        if item.isLive {
            // Modest forward buffer for live; AVFoundation still decides the real amount.
            playerItem.preferredForwardBufferDuration = 4
        }
        self.item = playerItem
        observe(playerItem)
        player.replaceCurrentItem(with: playerItem)
        if !item.isLive {
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 5, preferredTimescale: 600), queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let progress = self.currentProgress() else { return }
                    self.emit(.progress(position: progress.position, duration: progress.duration))
                }
            }
        }
    }

    public func currentProgress() -> (position: TimeInterval, duration: TimeInterval?)? {
        guard !isLive, let item else { return nil }
        let position = item.currentTime().seconds
        guard position.isFinite, position >= 0 else { return nil }
        let duration = item.duration.seconds
        return (position, duration.isFinite && duration > 0 ? duration : nil)
    }

    public func play() {
        guard !isStopped else { return }
        guard !isSeekingToStart else {
            playRequested = true
            return
        }
        player.play()
    }

    public func setExternalPlaybackAllowed(_ allowed: Bool) {
        player.allowsExternalPlayback = allowed
    }

    public func pause() {
        guard !isStopped else { return }
        player.pause()
    }

    public func stop() {
        guard !isStopped else { return }
        isStopped = true
        onEvent = nil
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        notificationTokens.removeAll()
        player.pause()
        item?.asset.cancelLoading()
        player.replaceCurrentItem(with: nil)
        item = nil
    }

    // MARK: - Observation

    private func observe(_ playerItem: AVPlayerItem) {
        observations.append(playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            Task { @MainActor [weak self] in self?.itemStatusChanged(status) }
        })
        observations.append(player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] player, _ in
            let active = player.isExternalPlaybackActive
            Task { @MainActor [weak self] in
                self?.emit(.note(active ? "External playback (AirPlay) active" : "External playback ended; playing on this device"))
            }
        })
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor [weak self] in self?.timeControlChanged(status) }
        })
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: playerItem, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.emit(.ended) }
        })
        notificationTokens.append(center.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: playerItem, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportItemFailure() }
        })
        notificationTokens.append(center.addObserver(
            forName: AVPlayerItem.playbackStalledNotification, object: playerItem, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stalled() }
        })
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status) {
        switch status {
        case .readyToPlay:
            if pendingStart > 0, let item {
                // Resume once, then forget it. Landing up to a few seconds early lets AVFoundation
                // start at a keyframe instead of decoding forward to an exact frame (much faster
                // over a progressive HTTP download); a short replay is acceptable when resuming.
                let target = CMTime(seconds: pendingStart, preferredTimescale: 600)
                pendingStart = 0
                item.seek(to: target, toleranceBefore: CMTime(seconds: 5, preferredTimescale: 600), toleranceAfter: .zero) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.initialSeekFinished() }
                }
            } else if isSeekingToStart {
                initialSeekFinished()
            }
            emit(.readyToPlay)
        case .failed: reportItemFailure()
        case .unknown: break
        @unknown default: break
        }
    }

    private func initialSeekFinished() {
        guard isSeekingToStart, !isStopped else { return }
        isSeekingToStart = false
        if playRequested {
            playRequested = false
            player.play()
        }
    }

    private func timeControlChanged(_ status: AVPlayer.TimeControlStatus) {
        switch status {
        case .playing:
            stallCount = 0
            emit(.playing)
        case .paused:
            // A failed item also pauses; let the failure path report it.
            if item?.status != .failed { emit(.paused) }
        case .waitingToPlayAtSpecifiedRate:
            emit(.buffering)
        @unknown default:
            break
        }
    }

    private func stalled() {
        stallCount += 1
        emit(.note("Playback stalled (\(stallCount))"))
        if stallCount >= 3 { emit(.failed(.stalled)) }
    }

    private func reportItemFailure() {
        guard let item, !isStopped else { return }
        let httpStatus = item.errorLog()?.events.last.map(\.errorStatusCode).flatMap { (100...599).contains($0) ? $0 : nil }
        if let error = item.error {
            emit(.note("Engine error: \(SanitizedError(error, redactor: redactor))"))
        }
        if let lastLog = item.errorLog()?.events.last {
            let origin = lastLog.uri.flatMap(URL.init(string:)).map(Redactor.describe) ?? "?"
            emit(.note("Error log: \(lastLog.errorDomain)#\(lastLog.errorStatusCode) at \(origin) \(redactor.redact(lastLog.errorComment ?? ""))"))
        }
        // Where the media request actually went (redirects change the host). Origin only.
        if let failing = Self.failingURL(in: item.error) {
            emit(.note("Failing request origin: \(Redactor.describe(failing))"))
        }
        if let access = item.accessLog()?.events.last, let uri = access.uri.flatMap(URL.init(string:)) {
            emit(.note("Last access origin: \(Redactor.describe(uri))"))
        }
        emit(.failed(Self.classify(error: item.error, httpStatus: httpStatus, redactor: redactor)))
    }

    private func emit(_ event: EngineEvent) {
        guard !isStopped else { return }
        onEvent?(event)
    }

    /// FourCC 'fmt?' as an OSStatus.
    nonisolated static let unsupportedDataFormatStatus = 0x666D_743F

    nonisolated static func failingURL(in error: Error?) -> URL? {
        var current = error as NSError?
        while let nsError = current {
            if let url = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL { return url }
            if let string = nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String, let url = URL(string: string) {
                return url
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return nil
    }

    /// Maps AVFoundation / CoreMedia / URL errors to a failure kind. Unrecognized codes stay
    /// `.unknown` with a sanitized identifier rather than a guessed cause.
    nonisolated static func classify(error: Error?, httpStatus: Int?, redactor: Redactor) -> PlaybackFailure {
        if let httpStatus {
            switch httpStatus {
            case 404, 410: return .streamNotFound
            case 401, 403: return .accessDenied(httpStatus: httpStatus)
            case 500...599: return .serverError(httpStatus: httpStatus)
            default: break
            }
        }
        guard let error else { return .unknown(nil) }
        var current: NSError? = error as NSError
        while let nsError = current {
            // 'fmt?' (kAudioFormatUnsupportedDataFormatError). Observed with a real provider whose
            // HLS carries MPEG-1 Layer II (.mp2) audio: CoreMedia cannot build the audio render
            // pipeline and halts, even though the H.264 video decodes.
            if nsError.code == Self.unsupportedDataFormatStatus {
                return .unsupportedFormat
            }
            if nsError.domain == NSURLErrorDomain {
                switch TransportFailure(urlErrorCode: nsError.code) {
                case .offline: return .offline
                case .timedOut: return .timedOut
                case .hostNotFound, .cannotConnect, .connectionLost: return .hostUnreachable
                case .insecureHTTPBlocked: return .insecureConnectionBlocked
                case .tlsFailure, .cancelled, .other: break
                }
                if nsError.code == NSURLErrorFileDoesNotExist || nsError.code == NSURLErrorResourceUnavailable {
                    return .streamNotFound
                }
                // Observed for HTTP 401/403 on HLS: the status code itself is not reported.
                if nsError.code == NSURLErrorNoPermissionsToReadFile || nsError.code == NSURLErrorUserAuthenticationRequired {
                    return .accessDenied(httpStatus: nil)
                }
            }
            // Observed with a real provider: CoreMedia surfaces the ATS refusal of a plain-HTTP
            // media request with the same code as NSURLErrorAppTransportSecurityRequiresSecureConnection.
            if nsError.domain == "CoreMediaErrorDomain" && nsError.code == NSURLErrorAppTransportSecurityRequiresSecureConnection {
                return .insecureConnectionBlocked
            }
            // Measured: the response to an HLS request was not a playlist (e.g. a provider that
            // answers `.m3u8` with raw MPEG-TS). AVPlayer cannot read it; VLC may.
            if nsError.domain == "CoreMediaErrorDomain" && nsError.code == -12646 {
                return .unsupportedFormat
            }
            if nsError.domain == AVFoundationErrorDomain {
                switch AVError.Code(rawValue: nsError.code) {
                case .fileFormatNotRecognized, .failedToParse, .decoderNotFound, .formatUnsupported:
                    return .unsupportedFormat
                case .serverIncorrectlyConfigured:
                    return .serverIncompatible
                default: break
                }
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return .unknown(SanitizedError(error, redactor: redactor))
    }
}
