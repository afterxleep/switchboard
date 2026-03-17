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
                .foregroundStyle(stateModel.daemonStatus == .running ? Color.green : Color.red)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}
