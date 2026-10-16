import SwiftUI

@main
struct SeyrileoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.live()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(.accent)
                .task { await model.launch() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await model.ensureFixtureServerIfNeeded() } }
                    // Whoever picks the device up later starts with locked content hidden.
                    if phase == .background { model.parental.lockNow() }
                }
        }
    }
}
