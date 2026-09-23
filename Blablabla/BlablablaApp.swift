import SwiftUI

@main
struct BlablablaApp: App {
    @StateObject private var coordinator = AppCoordinator()
    // Plain `let`, not @StateObject: a StateObject is created lazily on first
    // access, and the menu content that uses it isn't built until the menu is
    // opened — Sparkle would never run its background checks.
    private let updater = Updater()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(coordinator: coordinator, updater: updater)
        } label: {
            Image(coordinator.isRecording ? "MicRecording" : "MicIdle")
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(coordinator: coordinator)
        }
    }
}
