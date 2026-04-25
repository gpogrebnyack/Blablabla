import SwiftUI

@main
struct BlablablaApp: App {
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(coordinator: coordinator)
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
