import AVFoundation
import Observation
import SwiftUI
import UIKit
import UserNotifications

/// TV output for content the VLC engine plays. AirPlay *video* exists only for AVPlayer
/// (the receiver fetches the stream, and Apple TV cannot open MKV), so VLC content reaches
/// the TV through Screen Mirroring or a cable. While such an external display is connected,
/// iOS gives the app a separate external-display scene: Seyrileo shows the video there full
/// screen (not a copy of the phone UI) and keeps the controls on the phone.
@MainActor
@Observable
final class ExternalDisplayManager {
    static let shared = ExternalDisplayManager()

    private(set) var isConnected = false
    private(set) var displayName: String?

    /// VLC draws into this view while a display is connected.
    @ObservationIgnored let videoView: UIView = {
        let view = UIView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        return view
    }()
    @ObservationIgnored private var window: UIWindow?
    @ObservationIgnored private var idleLabel: UILabel?
    /// AVPlayer content: a second layer on the same player (the phone keeps its own view).
    @ObservationIgnored private let playerLayer: AVPlayerLayer = {
        let layer = AVPlayerLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
        return layer
    }()
    @ObservationIgnored private var layoutObservation: NSKeyValueObservation?

    func attach(_ scene: UIWindowScene) {
        let controller = UIViewController()
        controller.view.backgroundColor = .black
        videoView.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(videoView)
        let label = UILabel()
        label.text = "Seyrileo"
        label.textColor = UIColor(white: 1, alpha: 0.35)
        label.font = .systemFont(ofSize: 34, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(label)
        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
            videoView.topAnchor.constraint(equalTo: controller.view.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor),
            label.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor),
        ])
        videoView.layer.addSublayer(playerLayer)
        layoutObservation = videoView.layer.observe(\.bounds, options: [.initial, .new]) { [weak self] layer, _ in
            let bounds = layer.bounds
            Task { @MainActor [weak self] in self?.playerLayer.frame = bounds }
        }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.isHidden = false
        self.window = window
        idleLabel = label
        displayName = scene.screen.traitCollection.userInterfaceIdiom == .tv ? "TV" : nil
        isConnected = true
        setShowingVideo(false)
    }

    func detach() {
        layoutObservation?.invalidate()
        layoutObservation = nil
        playerLayer.player = nil
        playerLayer.removeFromSuperlayer()
        videoView.removeFromSuperview()
        window?.isHidden = true
        window = nil
        idleLabel = nil
        isConnected = false
        displayName = nil
    }

    /// Hides the idle logo while video is routed to the display.
    func setShowingVideo(_ showing: Bool) {
        idleLabel?.isHidden = showing
    }

    /// Shows an AVPlayer's picture on the display (nil for none; VLC draws into `videoView`).
    func show(player: AVPlayer?) {
        playerLayer.player = player
        playerLayer.frame = videoView.bounds
    }
}

final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        ExternalDisplayManager.shared.attach(windowScene)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        ExternalDisplayManager.shared.detach()
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Set before launch finishes so a tap that launched the app is delivered.
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        return true
    }

    func application(
        _ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        if connectingSceneSession.role == .windowExternalDisplayNonInteractive {
            configuration.delegateClass = ExternalDisplaySceneDelegate.self
        }
        return configuration
    }
}

/// Explains how to get VLC content onto the TV and shows whether a display is connected.
struct TVOutputSheet: View {
    @Environment(\.dismiss) private var dismiss
    let display = ExternalDisplayManager.shared

    var body: some View {
        NavigationStack {
            BrandList {
                Section {
                    Label {
                        Text(display.isConnected ? "TV connected. The video is shown on the TV in full screen." : "No TV connected yet.")
                    } icon: {
                        Image(systemName: display.isConnected ? "checkmark.circle.fill" : "tv")
                            .foregroundStyle(display.isConnected ? .green : .secondary)
                    }
                }
                Section {
                    Text("1. Open Control Center (swipe down from the top-right corner).")
                    Text("2. Tap Screen Mirroring.")
                    Text("3. Choose your TV or Apple TV.")
                    Text("Seyrileo then shows only the video on the TV and keeps the controls on this iPhone.")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Watch on TV")
                } footer: {
                    Text("With Screen Mirroring this iPhone loads and decodes the stream and sends the picture to the TV. It works for every title, including MKV files and channels the provider refuses to send to the TV directly over AirPlay.")
                }
            }
            .navigationTitle("Watch on TV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
