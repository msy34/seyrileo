import Foundation

public enum EngineEvent: Equatable, Sendable {
    case readyToPlay
    case playing
    case paused
    case buffering
    case ended
    case failed(PlaybackFailure)
    /// Periodic position for on-demand items (never emitted for live).
    case progress(position: TimeInterval, duration: TimeInterval?)
    /// Free-form, already-redacted note for the diagnostics log.
    case note(String)
    /// The user picked another audio or subtitle track in the engine's own controls.
    case tracksChosen(TrackPreference)
}

/// One playback backend instance. The coordinator creates a fresh instance per attempt and
/// must call `stop()` before discarding it; after `stop()` an engine emits no more events.
@MainActor
public protocol PlaybackEngine: AnyObject {
    var capabilities: EngineCapabilities { get }
    var onEvent: ((EngineEvent) -> Void)? { get set }
    func load(_ item: PlaybackItem)
    func play()
    func pause()
    /// Current position and duration for on-demand items; nil for live or before loading.
    func currentProgress() -> (position: TimeInterval, duration: TimeInterval?)?
    /// Whether the engine may hand the stream to an AirPlay receiver (which then fetches it itself).
    func setExternalPlaybackAllowed(_ allowed: Bool)
    /// Synchronously releases the stream, network resources, observers and timers.
    func stop()
}

@MainActor
public protocol PlaybackEngineFactory {
    var engineName: String { get }
    func makeEngine() -> PlaybackEngine
}
