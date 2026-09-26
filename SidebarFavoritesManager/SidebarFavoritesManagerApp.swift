import SwiftUI

@main
struct SidebarFavoritesManagerApp: App {
    @StateObject private var configManager = ConfigManager.shared
    @StateObject private var coordinator = FavoriteSyncCoordinator.shared
    @State private var showingAddSheet = false

    var body: some Scene {
        Window("Folder Icons", id: "main") {
            ContentView(showingAddSheet: $showingAddSheet)
                .environmentObject(configManager)
                .environmentObject(coordinator)
        }
        .defaultSize(width: 960, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
