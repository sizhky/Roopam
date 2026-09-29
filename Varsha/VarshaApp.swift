import SwiftUI

@main
struct VarshaApp: App {
    @ObservedObject private var settings = Settings.shared

    init() { RainController.shared.start() }

    var body: some Scene {
        MenuBarExtra("Varsha", systemImage: settings.raining ? "cloud.rain.fill" : "cloud") {
            MenuView()
        }
        .menuBarExtraStyle(.window)
    }
}
