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
    /// Our own full screen: video edge to edge, header and bottom bar hidden. Entered by
    /// turning an iPhone to landscape (or VLC's button); AVKit also has its own for AVPlayer.
    @State private var isImmersive = false
    /// Previous/next and episodes over AVKit's controls in full screen; hide after a while.
    @State private var overlayVisible = true
    @State private var overlayHide: Task<Void, Never>?
    @State private var showTVHelp = false
    @State private var showEpisodes = false
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

    private var currentEpisode: (episode: Episode, seriesTitle: String, posterURL: URL?)? {
        if case .episode(let episode, let title, let poster)? = currentEntry { return (episode, title, poster) }
        return nil
    }

    private var switcher: EntrySwitcher {
        EntrySwitcher(
            switches: entries.count > 1,
            isEpisode: currentEntry?.isEpisode == true,
            canGoBack: (currentIndex ?? 0) > 0,
            canGoForward: (currentIndex ?? .max) < entries.count - 1,
            go: { switchEntry(by: $0) },
            showEpisodes: currentEpisode == nil ? nil : { showEpisodes = true })
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
                    VLCControls(engine: vlc, state: playback.state, isImmersive: $isImmersive, switcher: switcher) { preference in
                        if let entry = currentEntry { app.saveTrackPreference(preference, for: entry) }
                    }
                } else if isImmersive {
                    ImmersiveOverlay(switcher: switcher) { isImmersive = false }
                        .opacity(overlayVisible ? 1 : 0)
                        .allowsHitTesting(overlayVisible)
                        .accessibilityHidden(!overlayVisible)
                        .animation(.easeInOut(duration: 0.2), value: overlayVisible)
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
            // Taps go to AVKit (or VLC's controls) as well; they also bring the overlay back.
            .simultaneousGesture(TapGesture().onEnded { showOverlay() })
            .accessibilityIdentifier("player.video")
            .overlay(alignment: .topLeading) { SessionProbe(playback: playback) }
            if !isImmersive { footer }
        }
        .statusBarHidden(isImmersive)
        .persistentSystemOverlays(isImmersive ? .hidden : .automatic)
        // Swipe down: back to the app with the mini player (and PiP when the content allows).
        .simultaneousGesture(
            DragGesture(minimumDistance: 30).onEnded { value in
                let move = value.translation
                guard move.height > 120, move.height > abs(move.width) * 2 else { return }
                app.minimizePlayer(startingPictureInPicture: true)
            })
        // iPhone landscape is full screen; back to portrait shows the header and bar again.
        .onChange(of: verticalSizeClass, initial: true) { _, sizeClass in
            isImmersive = sizeClass == .compact
        }
        .onChange(of: isImmersive) { _, _ in showOverlay() }
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
        .sheet(isPresented: $showEpisodes) {
            if let current = currentEpisode {
                EpisodesSheet(current: current.episode, seriesTitle: current.seriesTitle, seriesPosterURL: current.posterURL) { entry, all in
                    open(entry, in: all)
                }
            }
        }
        .parentalPrompt()
        .background(Color.black.ignoresSafeArea())
        // Scoped to the player; preferredColorScheme would also darken the presenting window.
        .environment(\.colorScheme, .dark)
        .alert(
            switchError.map { Text(app: $0.title) } ?? Text(verbatim: ""),
            isPresented: Binding(get: { switchError != nil }, set: { if !$0 { switchError = nil } }),
            presenting: switchError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { issue in
            Text(app: issue.detail)
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

    private func showOverlay() {
        overlayVisible = true
        overlayHide?.cancel()
        guard isImmersive else { return }
        overlayHide = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            overlayVisible = false
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.12), in: Circle())
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(Text("Close player"))
            Button {
                app.minimizePlayer()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.headline)
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.12), in: Circle())
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(Text("Minimize player"))
            VStack(alignment: .leading, spacing: 3) {
                Text(playback.currentItem?.title ?? "")
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                HStack(spacing: 6) {
                    if playback.currentItem?.isLive == true {
                        Text("Live")
                            .font(.caption2.weight(.heavy))
                            .textCase(.uppercase)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    if let channel = currentChannel, channel.epgChannelID != nil {
                        NowTitle(channel: channel, catalog: catalog)
                    } else if !catalog.source.isFixture {
                        Text(playback.currentItem?.sourceName ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if catalog.source.isFixture {
                        Text("Sample")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accent.opacity(0.25), in: Capsule())
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Landscape: room for the actions here; portrait keeps them in the bottom bar.
            if verticalSizeClass == .compact { actions }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(.white)
    }

    /// TV/AirPlay, favorite and diagnostics.
    @ViewBuilder
    private var actions: some View {
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
        if let channel = currentChannel {
            let isFavorite = catalog.isFavorite(channel.key)
            Button {
                Task { await catalog.toggleFavorite(channel) }
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.headline)
                    .foregroundStyle(isFavorite ? Color.brandAmber : .white)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(isFavorite ? Text("Remove from favorites") : Text("Add to favorites"))
        }
        if currentEpisode != nil {
            EpisodesButton { showEpisodes = true }
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

    @ViewBuilder
    private var footer: some View {
        // In landscape on iPhone the bar would cost video height; the actions move to the
        // header there.
        if verticalSizeClass != .compact {
            let episodes = currentEntry?.isEpisode == true
            let switches = entries.count > 1
            HStack(spacing: 4) {
                if switches {
                    Button { switchEntry(by: -1) } label: {
                        if episodes {
                            Label("Previous episode", systemImage: "backward.end.fill")
                        } else {
                            Label("Previous channel", systemImage: "chevron.up")
                        }
                    }
                    .frame(width: 44, height: 44)
                    .disabled((currentIndex ?? 0) == 0)
                }
                Spacer(minLength: 0)
                actions
                Spacer(minLength: 0)
                if switches {
                    Button { switchEntry(by: 1) } label: {
                        if episodes {
                            Label("Next episode", systemImage: "forward.end.fill")
                        } else {
                            Label("Next channel", systemImage: "chevron.down")
                        }
                    }
                    .frame(width: 44, height: 44)
                    .disabled((currentIndex ?? .max) >= entries.count - 1)
                }
            }
            .labelStyle(.iconOnly)
            .font(.headline)
            .tint(.white)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func switchEntry(by offset: Int) {
        guard let index = currentIndex, entries.indices.contains(index + offset) else { return }
        open(entries[index + offset])
    }

    /// Plays `target` in this player; `list` replaces what previous/next walks through.
    private func open(_ target: PlayableEntry, in list: [PlayableEntry]? = nil) {
        Task {
            do {
                // The coordinator saves the current item's position, then stops and releases its
                // stream before opening the next one.
                let item = try await app.playbackItem(for: target, start: .resumeIfPossible)
                if let list, list != entries { app.replacePlayerEntries(list) }
                playback.play(item)
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
        Text(title.map { String(app: "Now: \($0)") } ?? catalog.source.name)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .task(id: channel.key) {
                title = await catalog.nowNext(for: channel)?.now?.title
            }
    }
}
