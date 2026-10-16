import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        switch app.launchState {
        case .launching:
            // Continues the launch screen: the icon on navy, with walking paws.
            ZStack {
                BrandBackdrop()
                VStack(spacing: 28) {
                    BrandMark(size: 128)
                    PawLoader(size: 26, tint: .brandCream)
                }
            }
        case .failed(let reason):
            ContentUnavailableView {
                Label("Seyrileo couldn't open its data", systemImage: "externaldrive.badge.exclamationmark")
            } description: {
                Text("Your saved sources could not be read. Nothing was deleted. (\(reason))")
            }
        case .ready:
            if app.sources.isEmpty {
                WelcomeView()
            } else {
                MainTabView()
            }
        }
    }
}

enum AppTab: Hashable {
    case yourSpace, live, library, search, settings
}

struct MainTabView: View {
    @Environment(AppModel.self) private var app
    @State private var selection: AppTab = .live

    var body: some View {
        @Bindable var app = app
        tabs
            .overlay { MiniPlayerOverlay() }
            .fullScreenCover(item: $app.playerPresentation, onDismiss: {
                // The only place a full-screen session ends (unless it was minimized).
                app.playerDismissed()
            }) { presentation in
                if let catalog = app.activeCatalog {
                    PlayerScreen(catalog: catalog, presentation: presentation)
                }
            }
    }

    @ViewBuilder
    private var tabs: some View {
        if #available(iOS 18.0, *) {
            TabView(selection: $selection) {
                Tab("Your Space", systemImage: "square.grid.2x2", value: AppTab.yourSpace) { YourSpaceView() }
                Tab("Live", systemImage: "dot.radiowaves.left.and.right", value: AppTab.live) { LiveView() }
                Tab("Library", systemImage: "film.stack", value: AppTab.library) { LibraryView() }
                Tab("Search", systemImage: "magnifyingglass", value: AppTab.search) { SearchView() }
                Tab("Settings", systemImage: "gearshape", value: AppTab.settings) { SettingsView() }
            }
            .tabViewStyle(.sidebarAdaptable)
            .parentalPrompt()
        } else {
            TabView(selection: $selection) {
                YourSpaceView()
                    .tabItem { Label("Your Space", systemImage: "square.grid.2x2") }.tag(AppTab.yourSpace)
                LiveView()
                    .tabItem { Label("Live", systemImage: "dot.radiowaves.left.and.right") }.tag(AppTab.live)
                LibraryView()
                    .tabItem { Label("Library", systemImage: "film.stack") }.tag(AppTab.library)
                SearchView()
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(AppTab.search)
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }.tag(AppTab.settings)
            }
            .parentalPrompt()
        }
    }
}
