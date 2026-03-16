import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var stateModel: DaemonStateModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Switchboard")
                    .font(.headline)
                Spacer()
                HStack(spacing: 4) {
                    Circle()
                        .fill(stateModel.daemonStatusColor)
                        .frame(width: 8, height: 8)
                    Text(stateModel.daemonStatus.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Active Issues
            sectionHeader("Active Issues")
            if stateModel.activeEntries.isEmpty {
                menuRow("No active issues", dimmed: true)
            } else {
                let visible = Array(stateModel.activeEntries.prefix(8))
                ForEach(visible) { entry in
                    menuRow(entry.displayLabel, dimmed: false)
                }
                if stateModel.activeEntries.count > 8 {
                    menuRow("... \(stateModel.activeEntries.count - 8) more", dimmed: true)
                }
            }

            Divider().padding(.vertical, 4)

            // Parked
            sectionHeader("Parked")
            if stateModel.parkedEntries.isEmpty {
                menuRow("None", dimmed: true)
            } else {
                ForEach(stateModel.parkedEntries) { entry in
                    HStack {
                        Text(entry.displayLabel)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset") {
                            stateModel.resetEntry(entry.id)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
                }
            }

            Divider().padding(.vertical, 4)

            // Actions
            Button(stateModel.daemonStatus == .running ? "Stop Daemon" : "Start Daemon") {
                stateModel.toggleDaemon()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Button("Settings...") {
                if #available(macOS 14.0, *) {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                } else {
                    NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                }
                NSApp.activate(ignoringOtherApps: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Spacer().frame(height: 4)
        }
        .frame(width: 300)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    private func menuRow(_ text: String, dimmed: Bool) -> some View {
        Text(text)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(dimmed ? .secondary : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
    }
}
