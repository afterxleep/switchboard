import SwiftUI

@main
struct SwitchboardApp: App {
    @StateObject private var stateModel = DaemonStateModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(stateModel)
        } label: {
            Image(systemName: "cpu")
                .symbolRenderingMode(.palette)
                .foregroundStyle(stateModel.daemonStatusColor)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}
