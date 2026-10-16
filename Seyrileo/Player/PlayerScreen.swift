import AVKit
import SeyrileoKit
import SwiftUI

struct PlayerScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let catalog: SourceCatalogModel
    let presentation: PlayerPresentation
    @State private var showDiagnostics = false
    @State private var airPlay = ExternalPlaybackMonitor()
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var playback: PlaybackCoordinator { app.playback }

    @State private var switchError: UserIssue?
    /// VLC only: our own full screen (AVKit provides its own for AVPlayer).
    @State private var isImmersive = false
    @State private var showTVHelp = false
    private let externalDisplay = ExternalDisplayManager.shared

    private var vlcEngine: VLCEngine? { playback.engine as? VLCEngine }

    private var entries: [PlayableEntry] { presentation.entries }

    private var currentIndex: Int? {
        guard let id = playback.currentItem?.id else { return nil }
        return entries.firstIndex { $0.key == id }
    }

    private var currentEntry: PlayableEntry? { currentIndex.map { entries[$0] } }

    private var currentChannel: LiveChannel? {
        if case .channel(let channel)? = currentEntry { return channel }
        return nil
    }

    /// The next episode when the current item is an episode and one follows it.
    private var nextEpisode: PlayableEntry? {
        guard let index = currentIndex, entries[index].isEpisode, index + 1 < entries.count else { return nil }
        return entries[index + 1]
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isImmersive {
                header
                if airPlay.status != .local {
                    ExternalPlaybackBanner(status: airPlay.status, isFixture: catalog.source.isFixture, isVLC: vlcEngine != nil)
                }
            }
            ZStack {
                Color.black
                // Always mounted for the whole session: removing it while AVKit is in full
                // screen (e.g. during a retry) would tear the full-screen presentation down.
                SystemPlayerView(player: activePlayer)
                if let vlc = vlcEngine {
                    VLCSurface(engine: vlc).id(ObjectIdentifier(vlc))
                    if externalDisplay.isConnected {
                        VStack(spacing: 8) {
                            Image(systemName: "tv").font(.system(size: 44))
                            Text("Playing on the TV").font(.headline)
                        }
                        .foregroundStyle(.white.opacity(0.8))
                        .accessibilityElement(children: .combine)
                    }
                    VLCControls(engine: vlc, state: playback.state, isImmersive: $isImmersive) { preference in
                        if let entry = currentEntry { app.saveTrackPreference(preference, for: entry) }
                    }
                }
                StateOverlay(
                    state: playback.state, isExternal: airPlay.status != .local,
                    isFixture: catalog.source.isFixture, retry: { playback.retry() },
                    nextTitle: nextEpisode?.title, playNext: { switchEntry(by: 1) },
                    onDemandContainer: playback.currentItem.flatMap { $0.isLive ? nil : $0.url.pathExtension },
                    playLocally: {
                        // Same session, same single stream: retry on this device only.
                        playback.allowsExternalPlayback = false
                        playback.retry()
                    },
                    showTVHelp: { showTVHelp = true })
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(edges: isImmersive ? .all : [])
            .accessibilityIdentifier("player.video")
            .overlay(alignment: .topLeading) { SessionProbe(playback: playback) }
            if !isImmersive { footer }
        }
        .statusBarHidden(isImmersive)
        .persistentSystemOverlays(isImmersive ? .hidden : .automatic)
        .onChange(of: vlcEngine == nil) { _, isAVPlayer in
            if isAVPlayer { isImmersive = false }
        }
        // Route VLC's picture to the TV while an external display is connected; back to the
        // phone when it disconnects or the engine changes. AVPlayer handles the TV itself.
        .onChange(of: TVRouting(engine: playback.engine.map { ObjectIdentifier($0) }, connected: externalDisplay.isConnected), initial: true) { _, routing in
            // While mirroring, this iPhone decodes and the TV shows the picture full screen;
            // AirPlay's receiver-fetch mode is not used (one provider connection, the phone's).
            playback.allowsExternalPlayback = !routing.connected
            if let vlc = vlcEngine {
                externalDisplay.show(player: nil)
                vlc.render(into: routing.connected ? externalDisplay.videoView : nil)
            } else {
                externalDisplay.show(player: routing.connected ? activePlayer : nil)
            }
            externalDisplay.setShowingVideo(routing.connected && playback.engine != nil)
        }
        .onDisappear {
            externalDisplay.show(player: nil)
            externalDisplay.setShowingVideo(false)
        }
        .sheet(isPresented: $showTVHelp) { TVOutputSheet() }
        .parentalPrompt()
        .background(Color.black.ignoresSafeArea())
        // Scoped to the player; preferredColorScheme would also darken the presenting window.
        .environment(\.colorScheme, .dark)
        .alert(
            switchError.map { Text($0.title) } ?? Text(verbatim: ""),
            isPresented: Binding(get: { switchError != nil }, set: { if !$0 { switchError = nil } }),
            presenting: switchError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { issue in
            Text(issue.detail)
        }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsSheet(catalog: catalog, airPlayStatus: airPlay.status)
        }
        // No stop in onDisappear: AVKit's full screen and the AirPlay picker cover this view
        // and trigger onDisappear while the session must continue. The session ends only when
        // the player is closed (fullScreenCover onDismiss in PlayerLauncher).
        .onChange(of: ObjectIdentifier.optional(activePlayer), initial: true) { _, _ in
            airPlay.bind(activePlayer)
        }
        .onChange(of: airPlay.returnedToDevice) { _, returned in
            // AirPlay dropped: continue on this device with the same player and session.
            if returned, playback.state == .paused || playback.state == .buffering { playback.resume() }
        }
    }

    private var activePlayer: AVPlayer? { (playback.engine as? AVPlayerEngine)?.player }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(Text("Close player"))
            Button {
                app.minimizePlayer()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.headline)
                    .frame(width: 36, height: 44)
            }
            .accessibilityLabel(Text("Minimize player"))
            VStack(alignment: .leading, spacing: 2) {
                Text(playback.currentItem?.title ?? "")
                    .font(.headline)
                    .lineLimit(1)
                if let channel = currentChannel, channel.epgChannelID != nil {
                    NowTitle(channel: channel, catalog: catalog)
                } else {
                    Text(playback.currentItem?.sourceName ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if vlcEngine != nil {
                // VLC content: the AirPlay picker would only move the sound. Explain Screen
                // Mirroring instead, and show when the TV is in use.
                Button {
                    showTVHelp = true
                } label: {
                    Image(systemName: externalDisplay.isConnected ? "tv.fill" : "tv")
                        .font(.headline)
                        .foregroundStyle(externalDisplay.isConnected ? Color.accent : .white)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(Text("Watch on TV"))
            } else {
                RoutePickerButton()
                    .frame(width: 44, height: 44)
            }
            if catalog.source.isFixture {
                Text("Sample")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accent.opacity(0.2), in: Capsule())
            }
            if let channel = currentChannel {
                let isFavorite = catalog.isFavorite(channel.key)
                Button {
                    Task { await catalog.toggleFavorite(channel) }
                } label: {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.headline)
                        .foregroundStyle(isFavorite ? .yellow : .white)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(isFavorite ? Text("Remove from favorites") : Text("Add to favorites"))
            }
            Button {
                showDiagnostics = true
            } label: {
                Image(systemName: "stethoscope")
                    .font(.headline)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(Text("Connection diagnostics"))
        }
        .padding(.horizontal, 8)
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var footer: some View {
        // In landscape on iPhone the channel bar would cost video height; AVKit full screen
        // and portrait still offer it.
        if entries.count > 1 && verticalSizeClass != .compact {
            let episodes = currentEntry?.isEpisode == true
            HStack(spacing: 24) {
                Button { switchEntry(by: -1) } label: {
                    if episodes {
                        Label("Previous episode", systemImage: "backward.end")
                    } else {
                        Label("Previous channel", systemImage: "chevron.up")
                    }
                }
                .disabled((currentIndex ?? 0) == 0)
                Button { switchEntry(by: 1) } label: {
                    if episodes {
                        Label("Next episode", systemImage: "forward.end")
                    } else {
                        Label("Next channel", systemImage: "chevron.down")
                    }
                }
                .disabled((currentIndex ?? .max) >= entries.count - 1)
            }
            .labelStyle(.titleAndIcon)
            .font(.subheadline)
            .padding(.vertical, 12)
            .tint(.white)
        }
    }

    private func switchEntry(by offset: Int) {
        guard let index = currentIndex, entries.indices.contains(index + offset) else { return }
        let target = entries[index + offset]
        Task {
            do {
                // The coordinator saves the current item's position, then stops and releases its
                // stream before opening the next one.
                playback.play(try await app.playbackItem(for: target, start: .resumeIfPossible))
            } catch ParentalLockError.cancelled {
                // PIN prompt closed: stay on the current item.
            } catch {
                switchError = UserIssue(error)
            }
        }
    }
}

private struct StateOverlay: View {
    let state: PlaybackState
    let isExternal: Bool
    let isFixture: Bool
    let retry: () -> Void
    var nextTitle: String?
    var playNext: () -> Void = {}
    /// File type of the movie/episode being played; nil for live channels.
    var onDemandContainer: String?
    var playLocally: () -> Void = {}
    var showTVHelp: () -> Void = {}

    var body: some View {
        switch state {
        case .loading:
            ProgressLabel(text: "Connecting…")
        case .buffering:
            ProgressLabel(text: "Buffering…")
        case .retrying(let attempt, let total):
            ProgressLabel(text: "Reconnecting (\(attempt) of \(total))…")
        case .failed(let failure):
            ScrollView {
                VStack(spacing: 12) {
                    IssueView(
                        issue: UserIssue(playback: failure, isExternal: isExternal, isFixture: isFixture, onDemandContainer: onDemandContainer),
                        retry: retry)
                    if isExternal {
                        Button(action: playLocally) {
                            Label("Play on this iPhone", systemImage: "iphone")
                        }
                        .buttonStyle(.borderedProminent)
                        Button(action: showTVHelp) {
                            Label("Watch on TV with Screen Mirroring", systemImage: "tv")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding()
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: 520)
        case .ended:
            if let nextTitle {
                VStack(spacing: 12) {
                    Text("Up next").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(verbatim: nextTitle).font(.headline).multilineTextAlignment(.center)
                    Button(action: playNext) {
                        Label("Play next episode", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .frame(maxWidth: 420)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding()
            } else {
                Label("Ended", systemImage: "stop.circle")
                    .padding()
                    .background(.regularMaterial, in: Capsule())
            }
        case .idle, .playing, .paused:
            EmptyView()
        }
    }
}

private struct ProgressLabel: View {
    let text: LocalizedStringKey

    var body: some View {
        VStack(spacing: 10) {
            PawLoader(size: 34)
            Text(text)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

/// AVKit's standard player UI: native controls including full screen, AirPlay and the
/// audio/subtitle menu when the stream offers options. Picture in Picture is not enabled.
/// Full screen is AVKit's own presentation of the same AVPlayer: no second player or stream.
struct SystemPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer?

    func makeCoordinator() -> FullScreenContinuity { FullScreenContinuity() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        // Picture in Picture: AVKit's PiP button, and automatic PiP when the app is left.
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        controller.entersFullScreenWhenPlaybackBegins = false
        controller.exitsFullScreenWhenPlaybackEnds = false
        controller.delegate = context.coordinator
        controller.player = player
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: FullScreenContinuity) {
        controller.delegate = nil
        controller.player = nil
    }
}

/// AVKit pauses playback when full screen is closed with its Close/Done button (measured in
/// the UI test on iOS 27). For live TV, leaving full screen should only change the layout:
/// if the stream was playing when full screen started to close, the same AVPlayer resumes.
/// A pause the user chose inside full screen is respected.
final class FullScreenContinuity: NSObject, AVPlayerViewControllerDelegate {
    /// Returning from PiP: the player screen is still presented, so nothing to rebuild.
    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }

    /// Keep the player screen while PiP runs, so the session stays alive.
    func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(_ playerViewController: AVPlayerViewController) -> Bool {
        false
    }

    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
    ) {
        guard let player = playerViewController.player else { return }
        let wasPlaying = player.timeControlStatus != .paused || player.rate != 0
        coordinator.animate(alongsideTransition: nil) { context in
            guard !context.isCancelled, wasPlaying, playerViewController.player === player,
                  player.timeControlStatus == .paused
            else { return }
            player.play()
        }
    }
}

enum AudioSessionController {
    /// `.longFormVideo` lets the system offer and keep AirPlay video routes for this app.
    static func activateForPlayback() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
        try? session.setActive(true)
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// DEBUG-only, invisible element for UI tests: "state|player-identity". Contains no URLs,
/// usernames or passwords.
private struct SessionProbe: View {
    let playback: PlaybackCoordinator

    var body: some View {
        #if DEBUG
        let engine = playback.engine
        let identity = engine.map { "\($0.capabilities.engineName):" + String(UInt(bitPattern: ObjectIdentifier($0).hashValue), radix: 16) } ?? "none"
        let state = playback.state.diagnosticName.split(separator: ":").first.map(String.init) ?? ""
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityIdentifier("player.session")
            .accessibilityValue(Text(verbatim: "\(state)|\(identity)"))
        // Last diagnostic events (already redacted by the coordinator) for UI-test failure messages.
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityIdentifier("player.log")
            .accessibilityValue(Text(verbatim: playback.events.suffix(8).map(\.message).joined(separator: " ⏎ ")))
        #endif
    }
}

private struct TVRouting: Equatable {
    let engine: ObjectIdentifier?
    let connected: Bool
}

/// "Now: <programme>" for the player header.
private struct NowTitle: View {
    let channel: LiveChannel
    let catalog: SourceCatalogModel
    @State private var title: String?

    var body: some View {
        Text(title.map { String(localized: "Now: \($0)") } ?? catalog.source.name)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .task(id: channel.key) {
                title = await catalog.nowNext(for: channel)?.now?.title
            }
    }
}
