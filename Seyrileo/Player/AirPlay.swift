import AVFoundation
import AVKit
import Observation
import SwiftUI

/// Tracks AirPlay for the session's AVPlayer. Three separate facts:
/// - an AirPlay output is selected in the audio route (device chosen / connecting, or audio-only),
/// - the player actually hands video to the receiver (`isExternalPlaybackActive`),
/// - the route was lost and playback returned to this device.
@MainActor
@Observable
final class ExternalPlaybackMonitor {
    enum Status: Equatable {
        case local
        /// An AirPlay device is selected but the player is not (yet) playing on it.
        case routeSelected(deviceName: String?)
        /// The receiver is playing the stream.
        case active(deviceName: String?)
    }

    private(set) var status: Status = .local
    /// Becomes true once when an AirPlay route disappears while it was in use.
    private(set) var returnedToDevice = false

    @ObservationIgnored private weak var player: AVPlayer?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var routeToken: NSObjectProtocol?

    init() {
        routeToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    isolated deinit {
        if let routeToken { NotificationCenter.default.removeObserver(routeToken) }
        observation?.invalidate()
    }

    /// Follows the coordinator's current player (a new one per channel/attempt).
    func bind(_ player: AVPlayer?) {
        observation?.invalidate()
        self.player = player
        observation = player?.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.update() }
        }
        update()
    }

    private func update() {
        let airPlayOutput = AVAudioSession.sharedInstance().currentRoute.outputs.first { $0.portType == .airPlay }
        let next: Status
        if player?.isExternalPlaybackActive == true {
            next = .active(deviceName: airPlayOutput?.portName)
        } else if let airPlayOutput {
            next = .routeSelected(deviceName: airPlayOutput.portName)
        } else {
            next = .local
        }
        returnedToDevice = status != .local && next == .local
        status = next
    }
}

/// The system AirPlay device picker (AVRoutePickerView); no custom routing logic.
struct RoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = true
        view.tintColor = .white
        view.activeTintColor = UIColor(named: "AccentColor")
        view.accessibilityLabel = String(localized: "AirPlay")
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

struct ExternalPlaybackBanner: View {
    let status: ExternalPlaybackMonitor.Status
    let isFixture: Bool
    var isVLC = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch status {
            case .local:
                EmptyView()
            case .routeSelected(let name):
                Label {
                    Text("AirPlay device selected: \(name ?? String(localized: "unknown device")). Video is not playing on it yet.")
                } icon: {
                    Image(systemName: "airplayvideo")
                }
            case .active(let name):
                Label {
                    Text("Playing on \(name ?? String(localized: "an AirPlay device"))")
                } icon: {
                    Image(systemName: "tv")
                }
            }
            if isVLC, status != .local {
                Text("This title plays in VLC: AirPlay sends only its sound. Tap the TV button to show the picture on the TV with Screen Mirroring.")
                    .foregroundStyle(.secondary)
            }
            if isFixture, status != .local {
                Text("Sample streams are served from this phone only. An AirPlay receiver cannot reach them.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.accent.opacity(0.25))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("player.airplay")
    }
}

extension ObjectIdentifier {
    static func optional(_ object: AnyObject?) -> ObjectIdentifier? { object.map(ObjectIdentifier.init) }
}
