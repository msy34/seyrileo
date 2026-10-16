import Foundation

/// What the coordinator plays. `url` is credential-bearing for Xtream sources: it is never
/// logged or described, and diagnostics use `redactor` for any engine-supplied text.
public struct PlaybackItem: Identifiable, Equatable, Sendable, CustomStringConvertible {
    public let id: MediaKey
    public let title: String
    public let sourceName: String
    public let url: URL
    public let isLive: Bool
    public let redactor: Redactor
    /// Seconds to seek to before playback (resume). Always 0 for live streams.
    public let startPosition: TimeInterval
    /// Start with the alternate engine (e.g. a container the primary engine cannot open).
    public let prefersAlternateEngine: Bool
    /// The user's last audio/subtitle choice for this title (series, movie or channel).
    public let trackPreference: TrackPreference?

    public init(
        id: MediaKey, title: String, sourceName: String, url: URL, isLive: Bool, redactor: Redactor,
        startPosition: TimeInterval = 0, prefersAlternateEngine: Bool = false, trackPreference: TrackPreference? = nil
    ) {
        self.prefersAlternateEngine = prefersAlternateEngine
        self.trackPreference = trackPreference
        self.id = id
        self.title = title
        self.sourceName = sourceName
        self.url = url
        self.isLive = isLive
        self.redactor = redactor
        self.startPosition = isLive ? 0 : max(0, startPosition.isFinite ? startPosition : 0)
    }

    func starting(at position: TimeInterval) -> PlaybackItem {
        PlaybackItem(
            id: id, title: title, sourceName: sourceName, url: url, isLive: isLive, redactor: redactor,
            startPosition: position, prefersAlternateEngine: prefersAlternateEngine, trackPreference: trackPreference)
    }

    public func with(trackPreference: TrackPreference?) -> PlaybackItem {
        PlaybackItem(
            id: id, title: title, sourceName: sourceName, url: url, isLive: isLive, redactor: redactor,
            startPosition: startPosition, prefersAlternateEngine: prefersAlternateEngine, trackPreference: trackPreference)
    }

    public static func == (lhs: PlaybackItem, rhs: PlaybackItem) -> Bool {
        lhs.id == rhs.id && lhs.url == rhs.url && lhs.isLive == rhs.isLive && lhs.startPosition == rhs.startPosition
    }

    public var description: String { "PlaybackItem(\(id), \(Redactor.describe(url)))" }
}

/// Evidence-based playback failure. When the cause is not known it stays `.unknown`;
/// e.g. a 403 is reported as "access denied", never assumed to be a connection limit.
public enum PlaybackFailure: Equatable, Sendable {
    case offline
    case timedOut
    case hostUnreachable
    case insecureConnectionBlocked
    case streamNotFound
    /// The server refused access. `httpStatus` is nil when the engine did not report it.
    case accessDenied(httpStatus: Int?)
    case serverError(httpStatus: Int)
    case unsupportedFormat
    case stalled
    /// No first frame within the startup window and no error from the engine. The source
    /// may be slow, or the stream may contain no playable media; the engine cannot tell.
    case startupTimedOut
    /// The server answered in a way the engine rejects (e.g. AVFoundation -11850, often a
    /// server without byte-range support for a progressive file).
    case serverIncompatible
    case unknown(SanitizedError?)

    /// Worth a bounded automatic retry.
    public var isTransient: Bool {
        switch self {
        case .timedOut, .stalled: true
        case .serverError(let status): status >= 500
        case .offline, .hostUnreachable, .insecureConnectionBlocked, .streamNotFound, .accessDenied,
            .unsupportedFormat, .startupTimedOut, .serverIncompatible, .unknown:
            false
        }
    }

    /// Another engine might succeed where this one could not.
    /// Clear server/network answers (404, 403, offline, ATS…) are excluded: another engine
    /// would get the same answer. Unknown engine errors are included because they are usually
    /// demuxer/codec problems the other engine may handle.
    public var mayBenefitFromAlternateEngine: Bool {
        switch self {
        case .unsupportedFormat, .serverIncompatible, .startupTimedOut, .unknown: true
        default: false
        }
    }
}

public enum PlaybackState: Equatable, Sendable {
    case idle
    case loading
    case playing
    case paused
    case buffering
    case retrying(attempt: Int, of: Int)
    case failed(PlaybackFailure)
    case ended

    public var isActive: Bool {
        switch self {
        case .loading, .playing, .paused, .buffering, .retrying: true
        case .idle, .failed, .ended: false
        }
    }
}

public enum CapabilityStatus: String, Sendable {
    /// Verified on physical hardware for this engine.
    case verified
    /// The engine can do this in principle; not yet verified on device.
    case unverified
    /// Deliberately not enabled in this build.
    case notEnabled
    case unsupported
}

public struct EngineCapabilities: Equatable, Sendable {
    public var engineName: String
    public var hls: CapabilityStatus
    /// Live MPEG-TS over plain HTTP with no length or byte ranges (Xtream ".ts" output).
    public var liveMPEGTS: CapabilityStatus
    public var pictureInPicture: CapabilityStatus
    public var airPlay: CapabilityStatus
    public var trackSelection: CapabilityStatus

    public init(
        engineName: String, hls: CapabilityStatus, liveMPEGTS: CapabilityStatus, pictureInPicture: CapabilityStatus,
        airPlay: CapabilityStatus, trackSelection: CapabilityStatus
    ) {
        self.engineName = engineName
        self.hls = hls
        self.liveMPEGTS = liveMPEGTS
        self.pictureInPicture = pictureInPicture
        self.airPlay = airPlay
        self.trackSelection = trackSelection
    }
}

public struct DiagnosticEvent: Identifiable, Equatable, Sendable {
    public let id: Int
    public let date: Date
    public let message: String
}
