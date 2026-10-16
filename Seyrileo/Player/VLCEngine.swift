import AVKit
import MobileVLCKit
import SeyrileoKit
import UIKit

struct VLCEngineFactory: PlaybackEngineFactory {
    var engineName: String { VLCEngine.name }
    func makeEngine() -> PlaybackEngine { VLCEngine() }
}

/// Alternate engine (MobileVLCKit 3.7.4, LGPL-2.1, dynamically linked and unmodified) for
/// containers and codecs AVFoundation cannot play: MKV/AVI files, MPEG-1 Layer II audio,
/// live MPEG-TS. Used only when an item asks for it or AVPlayer reports a format problem.
/// No AirPlay video (VLC renders itself; only audio follows the route). Picture in Picture works
/// through `VLCFrameOutput` (VLC's frames shown in a sample-buffer layer) when available.
final class VLCEngine: NSObject, PlaybackEngine, VLCMediaPlayerDelegate {
    static let name = "VLC"

    var onEvent: ((EngineEvent) -> Void)?
    var capabilities: EngineCapabilities {
        EngineCapabilities(
            engineName: VLCEngine.name, hls: .unverified, liveMPEGTS: .unverified,
            pictureInPicture: frameOutput != nil ? .unverified : .unsupported,
            airPlay: .unsupported, trackSelection: .unverified)
    }
    /// The view showing the picture; hosted by the player screen or the mini player.
    let videoView: UIView
    /// Set when VLC's frames go to a sample-buffer layer (needed for PiP).
    private let frameOutput: VLCFrameOutput?
    private var pictureInPicture: AVPictureInPictureController?
    /// TV output view while an external display is connected (frame-output mode).
    private var externalView: SampleBufferView?

    private let player = VLCMediaPlayer()
    private var isLive = true
    private var isStopped = false
    private var hasReportedPlaying = false
    private var lastProgressEmit: TimeInterval = -10
    private var stopRequested = false
    /// The remembered audio/subtitle choice, applied once the tracks are known.
    private var trackPreference: TrackPreference?
    private var appliedAudio = false
    private var appliedSubtitle = false
    private var preferenceDeadline: Date?

    override init() {
        let output = VLCFrameOutput()
        if let handle = Self.libVLCPlayer(of: player), output.attach(toPlayer: handle) {
            frameOutput = output
            videoView = PrimaryLayerView(hosting: output.primaryLayer)
        } else {
            frameOutput = nil
            let view = UIView()
            view.backgroundColor = .black
            view.isUserInteractionEnabled = false
            videoView = view
        }
        super.init()
        player.delegate = self
        if frameOutput == nil {
            player.drawable = videoView
        } else {
            setUpPictureInPicture()
        }
    }

    /// The `libvlc_media_player_t` behind VLCMediaPlayer (VLCKit 3's `-libVLCMediaPlayer`,
    /// part of its internal interface). nil if this VLCKit build does not provide it.
    private static func libVLCPlayer(of player: VLCMediaPlayer) -> UnsafeMutableRawPointer? {
        let selector = NSSelectorFromString("libVLCMediaPlayer")
        guard player.responds(to: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> UnsafeMutableRawPointer?
        return unsafeBitCast(player.method(for: selector), to: Getter.self)(player, selector)
    }

    private func setUpPictureInPicture() {
        guard let frameOutput, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: frameOutput.primaryLayer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        // Leaving the app while VLC content plays continues it in PiP.
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.delegate = self
        pictureInPicture = controller
        // The layer is empty until VLC delivers a picture; ask the system to re-check whether
        // PiP is possible then, so leaving the app can start it automatically.
        frameOutput.onFirstFrame = { [weak self] in self?.pictureInPicture?.invalidatePlaybackState() }
    }

    /// PiP is offered for VLC content when the system says it is possible right now.
    var supportsPictureInPicture: Bool { pictureInPicture != nil }

    func togglePictureInPicture() {
        guard let pictureInPicture else { return }
        if pictureInPicture.isPictureInPictureActive {
            pictureInPicture.stopPictureInPicture()
        } else {
            pictureInPicture.invalidatePlaybackState()
            pictureInPicture.startPictureInPicture()
        }
    }

    func load(_ item: PlaybackItem) {
        guard !isStopped else { return }
        isLive = item.isLive
        trackPreference = item.trackPreference
        appliedAudio = item.trackPreference?.audio == nil
        appliedSubtitle = item.trackPreference.map { $0.subtitle == nil && !$0.subtitlesOff } ?? true
        preferenceDeadline = nil
        let media = VLCMedia(url: item.url)
        // Modest network cache; live a bit lower for latency.
        media.addOption(item.isLive ? ":network-caching=1500" : ":network-caching=2500")
        if frameOutput != nil {
            // Frame-output mode (needed for PiP): decode in software. With VideoToolbox the
            // pictures stay on the GPU and VLC does not draw subtitles onto the frames we get
            // (seen on iPhone: no subtitles; in the simulator, where VideoToolbox fails, they showed).
            media.addOption(":codec=avcodec")
            media.addOption(":avcodec-hw=none")
        }
        if item.startPosition > 0 {
            media.addOption(":start-time=\(Int(item.startPosition))")
        }
        player.media = media
    }

    func play() {
        guard !isStopped else { return }
        player.play()
    }

    func pause() {
        guard !isStopped else { return }
        player.pause()
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        stopRequested = true
        onEvent = nil
        pictureInPicture?.stopPictureInPicture()
        pictureInPicture?.delegate = nil
        pictureInPicture = nil
        player.delegate = nil
        player.stop()
        player.drawable = nil
        player.media = nil
        removeExternalView()
        frameOutput?.flush()
    }

    func setExternalPlaybackAllowed(_ allowed: Bool) {}

    /// Draw into another view (e.g. the external display) or back into `videoView` (nil).
    /// Same player and stream: VLC only changes where it renders.
    func render(into view: UIView?) {
        guard !isStopped else { return }
        guard let frameOutput else {
            player.drawable = view ?? videoView
            return
        }
        // Frame-output mode: the phone keeps its picture; the TV gets a second layer.
        removeExternalView()
        guard let view, view !== videoView else { return }
        let tv = SampleBufferView()
        tv.displayLayer.videoGravity = .resizeAspect
        tv.backgroundColor = .black
        tv.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tv)
        NSLayoutConstraint.activate([
            tv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tv.topAnchor.constraint(equalTo: view.topAnchor),
            tv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        frameOutput.addLayer(tv.displayLayer)
        externalView = tv
    }

    private func removeExternalView() {
        guard let externalView else { return }
        frameOutput?.removeLayer(externalView.displayLayer)
        externalView.removeFromSuperview()
        self.externalView = nil
    }

    func currentProgress() -> (position: TimeInterval, duration: TimeInterval?)? {
        guard !isLive, !isStopped else { return nil }
        let position = TimeInterval(player.time.intValue) / 1000
        guard position.isFinite, position >= 0 else { return nil }
        let length = TimeInterval(player.media?.length.intValue ?? 0) / 1000
        return (position, length > 0 ? length : nil)
    }

    // MARK: - Controls used by the player screen

    var isPlaying: Bool { player.isPlaying }
    var isSeekable: Bool { !isLive && player.isSeekable }

    func seek(to seconds: TimeInterval) {
        guard isSeekable else { return }
        player.time = VLCTime(int: Int32(max(0, seconds) * 1000))
    }

    var audioTracks: [(index: Int32, name: String)] { Self.tracks(player.audioTrackIndexes, player.audioTrackNames) }
    var currentAudioTrack: Int32 { player.currentAudioTrackIndex }
    func selectAudioTrack(_ index: Int32) { player.currentAudioTrackIndex = index }

    var subtitleTracks: [(index: Int32, name: String)] { Self.tracks(player.videoSubTitlesIndexes, player.videoSubTitlesNames) }
    var currentSubtitleTrack: Int32 { player.currentVideoSubTitleIndex }
    func selectSubtitleTrack(_ index: Int32) { player.currentVideoSubTitleIndex = index }

    private static func tracks(_ indexes: [Any], _ names: [Any]) -> [(index: Int32, name: String)] {
        zip(indexes, names).compactMap { index, name in
            guard let number = (index as? NSNumber)?.int32Value else { return nil }
            return (number, (name as? String) ?? "\(number)")
        }
    }

    // MARK: - VLCMediaPlayerDelegate (delivered on the main thread by VLCKit)

    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        MainActor.assumeIsolated { stateChanged() }
    }

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        MainActor.assumeIsolated { timeChanged() }
    }

    private func stateChanged() {
        guard !isStopped else { return }
        switch player.state {
        case .opening, .buffering:
            if !player.isPlaying { emit(.buffering) }
        case .playing:
            reportPlaying()
        case .paused:
            emit(.paused)
        case .ended:
            // A live stream has no end: the connection closed (bounded retry handles it).
            emit(isLive ? .failed(.stalled) : .ended)
        case .error:
            // libVLC does not say why (HTTP status, codec…); report it as unknown.
            emit(.note("VLC reported an error"))
            emit(.failed(.unknown(nil)))
        case .stopped:
            if !stopRequested, hasReportedPlaying {
                if isLive {
                    emit(.failed(.stalled))
                } else {
                    emit(.ended)
                }
            }
        case .esAdded:
            updatePixelAspect()
            applyTrackPreference()
        @unknown default:
            break
        }
    }

    /// Re-applies the remembered tracks. Subtitle tracks of some files appear a little after
    /// playback starts, so this keeps trying for a few seconds.
    private func applyTrackPreference() {
        guard let preference = trackPreference, !(appliedAudio && appliedSubtitle) else { return }
        if preferenceDeadline == nil, player.isPlaying { preferenceDeadline = Date().addingTimeInterval(8) }
        if let deadline = preferenceDeadline, Date() > deadline {
            appliedAudio = true
            appliedSubtitle = true
            return
        }
        if !appliedAudio, let wanted = preference.audio, audioTracks.contains(where: { $0.index >= 0 }) {
            if let index = TrackMatcher.bestMatch(wanted, among: audioTracks) {
                player.currentAudioTrackIndex = index
            }
            appliedAudio = true
        }
        if !appliedSubtitle {
            if preference.subtitlesOff {
                // VLC may switch a default subtitle on as tracks appear; keep it off meanwhile.
                if player.currentVideoSubTitleIndex != -1 { player.currentVideoSubTitleIndex = -1 }
            } else if let wanted = preference.subtitle, let index = TrackMatcher.bestMatch(wanted, among: subtitleTracks) {
                player.currentVideoSubTitleIndex = index
                appliedSubtitle = true
            }
        }
    }

    /// The current choice, for remembering it.
    var currentTrackPreference: TrackPreference {
        let audioName = audioTracks.first { $0.index == currentAudioTrack }?.name
        let subtitleIndex = currentSubtitleTrack
        let subtitleName = subtitleIndex >= 0 ? subtitleTracks.first { $0.index == subtitleIndex }?.name : nil
        return TrackPreference(audio: audioName, subtitle: subtitleName, subtitlesOff: subtitleIndex < 0)
    }

    private func timeChanged() {
        guard !isStopped else { return }
        applyTrackPreference()
        reportPlaying()
        guard let progress = currentProgress(), abs(progress.position - lastProgressEmit) >= 5 else { return }
        lastProgressEmit = progress.position
        emit(.progress(position: progress.position, duration: progress.duration))
    }

    /// Non-square pixels (anamorphic video) must be told to the sample-buffer layer.
    private func updatePixelAspect() {
        guard let frameOutput, let tracks = player.media?.tracksInformation as? [[String: Any]] else { return }
        for track in tracks where (track[VLCMediaTracksInformationType] as? String) == VLCMediaTracksInformationTypeVideo {
            let numerator = (track[VLCMediaTracksInformationSourceAspectRatio] as? NSNumber)?.intValue ?? 0
            let denominator = (track[VLCMediaTracksInformationSourceAspectRatioDenominator] as? NSNumber)?.intValue ?? 0
            if numerator > 0, denominator > 0 {
                frameOutput.setPixelAspect(numerator, denominator)
                return
            }
        }
    }

    private func reportPlaying() {
        if !hasReportedPlaying { updatePixelAspect() }
        guard player.isPlaying else { return }
        if !hasReportedPlaying {
            hasReportedPlaying = true
            emit(.note("VLC playing"))
        }
        emit(.playing)
    }

    private func emit(_ event: EngineEvent) {
        guard !isStopped else { return }
        switch event {
        case .playing, .paused, .ended, .failed: pictureInPicture?.invalidatePlaybackState()
        default: break
        }
        onEvent?(event)
    }
}

// MARK: - Picture in Picture (frame-output mode)

extension VLCEngine: AVPictureInPictureSampleBufferPlaybackDelegate, AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        MainActor.assumeIsolated { playing ? play() : pause() }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        MainActor.assumeIsolated {
            guard !isLive, let progress = currentProgress(), let duration = progress.duration else {
                // Live: no fixed range; PiP shows a live indicator.
                return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
            }
            // The range is anchored so that "now" in the host clock is the current position.
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            let start = CMTimeSubtract(now, CMTime(seconds: progress.position, preferredTimescale: 600))
            return CMTimeRange(start: start, duration: CMTime(seconds: duration, preferredTimescale: 600))
        }
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        MainActor.assumeIsolated { !player.isPlaying }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void
    ) {
        MainActor.assumeIsolated {
            if let position = currentProgress()?.position { seek(to: position + skipInterval.seconds) }
        }
        completionHandler()
    }

    /// Back from PiP: the player (full screen or mini) is still there.
    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}
