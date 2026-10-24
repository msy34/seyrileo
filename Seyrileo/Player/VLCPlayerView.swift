import SeyrileoKit
import SwiftUI
import UIKit

/// Hosts the VLC engine's own drawing view. Keyed by engine identity by the caller.
struct VLCSurface: UIViewRepresentable {
    let engine: VLCEngine

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        let video = engine.videoView
        video.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(video)
        NSLayoutConstraint.activate([
            video.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            video.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            video.topAnchor.constraint(equalTo: container.topAnchor),
            video.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        uiView.subviews.forEach { $0.removeFromSuperview() }
    }
}

/// Minimal native-style controls for the VLC engine (AVKit's controls only drive AVPlayer).
/// Tap the video to show or hide them; they hide themselves after a few seconds of playback.
struct VLCControls: View {
    let engine: VLCEngine
    let state: PlaybackState
    @Binding var isImmersive: Bool
    /// Previous/next and episodes, shown on the video in full screen (the bottom bar is hidden).
    var switcher: EntrySwitcher?
    /// Called after the user picks an audio or subtitle track (to remember it).
    var onTracksChosen: (TrackPreference) -> Void = { _ in }
    @State private var visible = true
    @State private var scrubbing: Double?
    @State private var hideTask: Task<Void, Never>?
    @State private var menuOpen = false

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { toggle() }
                .accessibilityHidden(true)
            // Hidden controls stay in the hierarchy (invisible, not tappable): removing them
            // would also close an open audio/subtitle menu. Only the position bar ticks.
            controls
                .opacity(visible ? 1 : 0)
                .allowsHitTesting(visible)
                .accessibilityHidden(!visible)
        }
        .animation(.easeInOut(duration: 0.2), value: visible)
        .onAppear { scheduleHide() }
        .onChange(of: state) { _, newState in
            if newState == .playing { scheduleHide() } else { visible = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.vlc")
    }

    private var isLoading: Bool {
        switch state {
        case .loading, .buffering, .retrying: true
        default: false
        }
    }

    private var controls: some View {
        VStack {
            HStack {
                if engine.supportsPictureInPicture {
                    Button {
                        engine.togglePictureInPicture()
                    } label: {
                        Image(systemName: "pip.enter")
                            .font(.headline)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(Text("Picture in Picture"))
                }
                Spacer()
                if isImmersive, let showEpisodes = switcher?.showEpisodes {
                    EpisodesButton {
                        showEpisodes()
                        scheduleHide()
                    }
                }
                trackMenu
                Button {
                    isImmersive.toggle()
                    scheduleHide()
                } label: {
                    Image(systemName: isImmersive ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.headline)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(isImmersive ? Text("Exit full screen") : Text("Full screen"))
            }
            Spacer()
            HStack(spacing: 40) {
                if isImmersive, let switcher, switcher.switches { EntrySwitchButton(offset: -1, switcher: switcher) }
                // While loading, the paw loader is shown in the middle instead.
                if isLoading {
                    Color.clear.frame(width: 72, height: 72)
                } else {
                    playPauseButton
                }
                if isImmersive, let switcher, switcher.switches { EntrySwitchButton(offset: 1, switcher: switcher) }
            }
            Spacer()
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                positionBar
            }
            Text("VLC").font(.caption2).foregroundStyle(.white.opacity(0.6)).padding(.bottom, 6)
        }
        .foregroundStyle(.white)
        .tint(.accent)
        .padding(8)
        .background(LinearGradient(colors: [.black.opacity(0.55), .clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
    }

    private var playPauseButton: some View {
        Button {
                if engine.isPlaying { engine.pause() } else { engine.play() }
                scheduleHide()
            } label: {
                Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .frame(width: 72, height: 72)
                    .background(.black.opacity(0.35), in: Circle())
            }
            .accessibilityLabel(engine.isPlaying ? Text("Pause") : Text("Play"))
    }

    @ViewBuilder
    private var positionBar: some View {
        let progress = engine.currentProgress()
        if engine.isSeekable, let progress, let duration = progress.duration, duration > 0 {
                VStack(spacing: 4) {
                    Slider(
                        value: Binding(
                            get: { scrubbing ?? progress.position },
                            set: { scrubbing = $0 }),
                        in: 0...duration,
                        onEditingChanged: { editing in
                            if !editing, let target = scrubbing {
                                engine.seek(to: target)
                                scrubbing = nil
                                scheduleHide()
                            } else {
                                hideTask?.cancel()
                            }
                        })
                    .accessibilityLabel(Text("Position"))
                    HStack {
                        Text(DurationText.clock(scrubbing ?? progress.position))
                        Spacer()
                        Text(DurationText.clock(duration))
                    }
                    .font(.caption.monospacedDigit())
                }
                .padding(.horizontal)
            }
    }

    @ViewBuilder
    private var trackMenu: some View {
        let audio = engine.audioTracks
        let subtitles = engine.subtitleTracks
        if audio.count > 1 || subtitles.count > 1 {
            Menu {
                // Menu content exists only while the menu is open: use that to hold auto-hide.
                Color.clear.frame(width: 0, height: 0)
                    .onAppear { menuOpen = true; hideTask?.cancel() }
                    .onDisappear { menuOpen = false; scheduleHide() }
                // Plain buttons per section: two Pickers in one Menu share tag values (track
                // numbers overlap between audio and subtitles) and SwiftUI may route a tap to the
                // wrong one.
                if audio.count > 1 {
                    Section("Audio") {
                        ForEach(audio, id: \.index) { track in
                            trackButton(track.index < 0 ? String(app: "Off") : track.name,
                                        isOn: track.index == engine.currentAudioTrack) {
                                engine.selectAudioTrack(track.index)
                            }
                        }
                    }
                }
                if subtitles.count > 1 {
                    Section("Subtitles") {
                        ForEach(subtitles, id: \.index) { track in
                            trackButton(track.index < 0 ? String(app: "Off") : track.name,
                                        isOn: track.index == engine.currentSubtitleTrack) {
                                engine.selectSubtitleTrack(track.index)
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "text.bubble").font(.headline).frame(width: 44, height: 44)
            }

            .accessibilityLabel(Text("Audio and subtitles"))
        }
    }

    private func trackButton(_ name: String, isOn: Bool, select: @escaping () -> Void) -> some View {
        Button {
            select()
            onTracksChosen(engine.currentTrackPreference)
            scheduleHide()
        } label: {
            if isOn {
                Label(name, systemImage: "checkmark")
            } else {
                Text(verbatim: name)
            }
        }
    }

    private func toggle() {
        visible.toggle()
        if visible { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard state == .playing, !menuOpen else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, scrubbing == nil else { return }
            visible = false
        }
    }
}
