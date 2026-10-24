import SwiftUI

@main
struct SeyrileoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.live()
    @State private var languages = LanguageSettings()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                // Rebuilt when the language changes so every string is looked up again.
                .id(languages.current)
                .environment(\.locale, languages.current.locale)
                .environment(\.layoutDirection, languages.current.isRightToLeft ? .rightToLeft : .leftToRight)
                .environment(languages)
                .environment(model)
                .tint(.accent)
                // Always the icon's night look (owner decision, 2026-10-17).
                .preferredColorScheme(.dark)
                .task { await model.launch() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await model.ensureFixtureServerIfNeeded() } }
                    // Whoever picks the device up later starts with locked content hidden.
                    if phase == .background { model.parental.lockNow() }
                }
        }
    }
}
