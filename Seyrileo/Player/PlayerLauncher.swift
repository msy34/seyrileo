import Observation
import SeyrileoKit
import SwiftUI

struct PlayerPresentation: Identifiable {
    let id: UUID
    /// What previous/next walks through (channels of a list, or episodes of a series).
    let entries: [PlayableEntry]

    init(id: UUID = UUID(), entries: [PlayableEntry]) {
        self.id = id
        self.entries = entries
    }
}

/// Starts playback from any list (channels, movies, episodes); the root view presents the
/// player (`AppModel.playerPresentation`) so it can be minimized while browsing.
@MainActor
@Observable
final class PlayerLauncher {
    var error: UserIssue?
    private(set) var isStarting = false
    @ObservationIgnored private weak var app: AppModel?

    func attach(_ app: AppModel) { self.app = app }

    func play(_ channel: LiveChannel, in list: [LiveChannel], catalog: SourceCatalogModel) {
        Task { await play(.channel(channel), in: list.map(PlayableEntry.channel)) }
    }

    func play(_ entry: PlayableEntry, in entries: [PlayableEntry], start: StartPreference = .resumeIfPossible) async {
        guard let app, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        do {
            let item = try await app.playbackItem(for: entry, start: start)
            AudioSessionController.activateForPlayback()
            app.playback.play(item)
            app.presentPlayer(PlayerPresentation(entries: entries.contains(entry) ? entries : [entry]))
        } catch ParentalLockError.cancelled {
            // The user closed the PIN prompt: nothing to report.
        } catch {
            self.error = UserIssue(error)
        }
    }
}

extension View {
    func playerPresentation(_ launcher: PlayerLauncher, catalog: SourceCatalogModel) -> some View {
        modifier(PlayerPresentationModifier(launcher: launcher, catalog: catalog))
    }
}

private struct PlayerPresentationModifier: ViewModifier {
    @Environment(AppModel.self) private var app
    @Bindable var launcher: PlayerLauncher
    let catalog: SourceCatalogModel

    func body(content: Content) -> some View {
        content
            .onAppear { launcher.attach(app) }
            .alert(
                launcher.error.map { Text(app: $0.title) } ?? Text(verbatim: ""),
                isPresented: Binding(get: { launcher.error != nil }, set: { if !$0 { launcher.error = nil } }),
                presenting: launcher.error
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { issue in
                Text(app: issue.detail)
            }
    }
}
