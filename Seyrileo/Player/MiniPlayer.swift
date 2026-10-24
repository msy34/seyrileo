import AVKit
import SeyrileoKit
import SwiftUI

/// The floating player shown while the user browses with a minimized session. Same engine and
/// stream as the full-screen player (nothing is reopened). Drag it to any corner; tap the
/// video to return to full screen.
struct MiniPlayerOverlay: View {
    @Environment(AppModel.self) private var app
    @State private var corner: Corner = .bottomTrailing
    @State private var drag: CGSize = .zero

    enum Corner: CaseIterable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing
        var alignment: Alignment {
            switch self {
            case .topLeading: .topLeading
            case .topTrailing: .topTrailing
            case .bottomLeading: .bottomLeading
            case .bottomTrailing: .bottomTrailing
            }
        }
        var isTop: Bool { self == .topLeading || self == .topTrailing }
        var isLeading: Bool { self == .topLeading || self == .bottomLeading }
    }

    var body: some View {
        GeometryReader { proxy in
            if app.miniPresentation != nil {
                MiniPlayerCard()
                    .frame(width: min(240, proxy.size.width * 0.55))
                    .offset(drag)
                    .padding(.horizontal, 12)
                    .padding(.top, corner.isTop ? 8 : 0)
                    // Clear of the tab bar at the bottom.
                    .padding(.bottom, corner.isTop ? 0 : 96)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner.alignment)
                    .gesture(
                        DragGesture()
                            .onChanged { drag = $0.translation }
                            .onEnded { value in
                                let x = (corner.isLeading ? 0 : proxy.size.width) + value.predictedEndTranslation.width
                                let y = (corner.isTop ? 0 : proxy.size.height) + value.predictedEndTranslation.height
                                let leading = x < proxy.size.width / 2
                                let top = y < proxy.size.height / 2
                                withAnimation(.snappy) {
                                    corner = top ? (leading ? .topLeading : .topTrailing) : (leading ? .bottomLeading : .bottomTrailing)
                                    drag = .zero
                                }
                            }
                    )
                    .transition(.scale(scale: 0.6, anchor: .bottomTrailing).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: app.miniPresentation != nil)
    }
}

private struct MiniPlayerCard: View {
    @Environment(AppModel.self) private var app
    /// Swipe-down minimize: start Picture in Picture when the content supports it.
    @State private var startsPictureInPicture = false

    private var playback: PlaybackCoordinator { app.playback }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let vlc = playback.engine as? VLCEngine {
                    VLCSurface(engine: vlc)
                        .id(ObjectIdentifier(vlc))
                        // Draw here again (the full-screen player may have sent it to the TV).
                        .onAppear {
                            vlc.render(into: nil)
                            vlc.onRestoreFromPictureInPicture = { [weak app] in app?.expandMiniPlayer() }
                        }
                } else if let player = (playback.engine as? AVPlayerEngine)?.player {
                    PiPPlayerLayerView(player: player, startsPictureInPicture: startsPictureInPicture) { app.expandMiniPlayer() }
                        .id(ObjectIdentifier(player))
                }
                stateBadge
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .contentShape(Rectangle())
            .onTapGesture { app.expandMiniPlayer() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(playback.currentItem?.title ?? ""))
            .accessibilityHint(Text("Opens the player"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { app.expandMiniPlayer() }

            HStack(spacing: 4) {
                Text(playback.currentItem?.title ?? "")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    if playback.state == .playing { playback.pause() } else { playback.resume() }
                } label: {
                    Image(systemName: playback.state == .playing ? "pause.fill" : "play.fill")
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel(Text(playback.state == .playing ? "Pause" : "Play"))
                Button { app.closeMiniPlayer() } label: {
                    Image(systemName: "xmark").frame(width: 32, height: 32)
                }
                .accessibilityLabel(Text("Close player"))
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .frame(height: 40)
            .foregroundStyle(.white)
        }
        .background(Color(white: 0.12))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.mini")
        // Read once; the AVPlayer layer view picks it up on its next update.
        .onAppear { startsPictureInPicture = app.takePictureInPictureRequest() }
        .onChange(of: startsPictureInPicture) { _, starts in
            if starts, let vlc = playback.engine as? VLCEngine { vlc.startPictureInPicture() }
        }
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch playback.state {
        case .loading, .buffering, .retrying:
            PawLoader(size: 22, tint: .white)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        default:
            EmptyView()
        }
    }
}

/// An AVPlayerLayer that can go Picture in Picture by itself when the app is left
/// (`canStartPictureInPictureAutomaticallyFromInline`). Used by the mini player; the
/// full-screen player uses AVPlayerViewController's own PiP.
struct PiPPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    var startsPictureInPicture = false
    let restore: () -> Void

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    final class Coordinator: NSObject, AVPictureInPictureControllerDelegate {
        var controller: AVPictureInPictureController?
        var restore: () -> Void = {}
        let starter = PictureInPictureStarter()
        var startedOnce = false

        func pictureInPictureController(
            _ pictureInPictureController: AVPictureInPictureController,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
        ) {
            restore()
            completionHandler(true)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        if AVPictureInPictureController.isPictureInPictureSupported(),
           let controller = AVPictureInPictureController(playerLayer: view.playerLayer) {
            controller.canStartPictureInPictureAutomaticallyFromInline = true
            controller.delegate = context.coordinator
            context.coordinator.controller = controller
        }
        context.coordinator.restore = restore
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        context.coordinator.restore = restore
        if startsPictureInPicture, !context.coordinator.startedOnce, let controller = context.coordinator.controller {
            context.coordinator.startedOnce = true
            context.coordinator.starter.start(controller)
        }
    }

    static func dismantleUIView(_ view: LayerView, coordinator: Coordinator) {
        coordinator.starter.cancel()
        coordinator.controller?.delegate = nil
        coordinator.controller = nil
        view.playerLayer.player = nil
    }
}
