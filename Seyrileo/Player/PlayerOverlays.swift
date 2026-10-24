import AVKit
import SwiftUI

/// Previous/next and "Show episodes" for overlays drawn on the video (full screen).
struct EntrySwitcher {
    /// More than one entry to walk through.
    var switches: Bool
    var isEpisode: Bool
    var canGoBack: Bool
    var canGoForward: Bool
    var go: (Int) -> Void
    /// Set while an episode is playing.
    var showEpisodes: (() -> Void)?
}

/// A round previous/next button for the video overlay.
struct EntrySwitchButton: View {
    /// -1 previous, +1 next.
    let offset: Int
    let switcher: EntrySwitcher

    var body: some View {
        Button { switcher.go(offset) } label: {
            Group {
                if switcher.isEpisode {
                    if offset < 0 {
                        Label("Previous episode", systemImage: "backward.end.fill")
                    } else {
                        Label("Next episode", systemImage: "forward.end.fill")
                    }
                } else if offset < 0 {
                    Label("Previous channel", systemImage: "chevron.up")
                } else {
                    Label("Next channel", systemImage: "chevron.down")
                }
            }
            .labelStyle(.iconOnly)
            .font(.system(size: 20, weight: .semibold))
            .frame(width: 52, height: 52)
            .background(.black.opacity(0.4), in: Circle())
        }
        .disabled(offset < 0 ? !switcher.canGoBack : !switcher.canGoForward)
    }
}

struct EpisodesButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Show episodes", systemImage: "rectangle.stack")
                .labelStyle(.iconOnly)
                .font(.headline)
                .frame(width: 44, height: 44)
        }
    }
}

/// Full screen with the built-in player: AVKit's controls fill the screen, so previous/next,
/// episodes and "exit full screen" sit at the side edges, where AVKit draws nothing.
struct ImmersiveOverlay: View {
    let switcher: EntrySwitcher
    let exit: () -> Void

    var body: some View {
        HStack {
            VStack(spacing: 18) {
                if switcher.switches { EntrySwitchButton(offset: -1, switcher: switcher) }
                Button(action: exit) {
                    Label("Exit full screen", systemImage: "arrow.down.right.and.arrow.up.left")
                        .labelStyle(.iconOnly)
                        .font(.headline)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.4), in: Circle())
                }
            }
            Spacer()
            VStack(spacing: 18) {
                if switcher.switches { EntrySwitchButton(offset: 1, switcher: switcher) }
                if let showEpisodes = switcher.showEpisodes {
                    EpisodesButton(action: showEpisodes)
                        .background(.black.opacity(0.4), in: Circle())
                }
            }
        }
        .foregroundStyle(.white)
        .tint(.white)
        .padding(.horizontal, 12)
    }
}

/// Starts Picture in Picture as soon as the system allows it: right after minimizing, the
/// picture has just moved to a new layer and PiP is not possible yet.
@MainActor
final class PictureInPictureStarter {
    private var observation: NSKeyValueObservation?

    func start(_ controller: AVPictureInPictureController) {
        observation = nil
        guard !controller.isPictureInPictureActive else { return }
        if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
            return
        }
        nonisolated(unsafe) let target = controller
        observation = controller.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] _, change in
            guard change.newValue == true else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self?.observation != nil else { return }
                    self?.observation = nil
                    target.startPictureInPicture()
                }
            }
        }
    }

    func cancel() { observation = nil }
}
