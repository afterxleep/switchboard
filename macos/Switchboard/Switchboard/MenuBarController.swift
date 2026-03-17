import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var stateModel: DaemonStateModel
    @State private var showClearConfirm = false

    private let maxVisible = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if stateModel.daemonStatus == .stopped {
                daemonWarning
                Divider()
            }

            inProgressSection
            Divider().padding(.vertical, 2)
            stuckSection
            Divider().padding(.vertical, 2)
            footer
        }
        .frame(width: 320)
        .alert("Clear All Entries?", isPresented: $showClearConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                stateModel.clearAll()
            }
        } message: {
            Text("This will delete all entries from the database. This cannot be undone.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.system(.body, design: .monospaced))
                Text("Switchboard")
                    .font(.system(.body, design: .monospaced).bold())
            }
            Spacer()
            HStack(spacing: 5) {
                Circle()
                    .fill(stateModel.daemonStatus.color)
                    .frame(width: 8, height: 8)
                Text(stateModel.daemonStatus.label)
                    .font(.system(.caption))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Daemon Warning

    private var daemonWarning: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.caption)
            Text("Daemon is stopped")
                .font(.system(.caption))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Start") {
                stateModel.toggleDaemon()
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(.blue)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.yellow.opacity(0.08))
    }

    // MARK: - In Progress

    private var inProgressSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("IN PROGRESS", count: stateModel.inProgressEntries.count)

            if stateModel.inProgressEntries.isEmpty {
                emptyRow("No active items")
            } else {
                let visible = Array(stateModel.inProgressEntries.prefix(maxVisible))
                ForEach(visible) { entry in
                    inProgressRow(entry)
                }
                let remaining = stateModel.inProgressEntries.count - maxVisible
                if remaining > 0 {
                    Text("… \(remaining) more")
                        .font(.system(.caption))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 3)
                }
            }
        }
    }

    private func inProgressRow(_ entry: StateEntry) -> some View {
        HStack(spacing: 0) {
            Circle()
                .fill(Color.green)
                .frame(width: 6, height: 6)
                .padding(.trailing, 8)

            Text(entry.displayLabel)
                .font(.system(.body, design: .monospaced).bold())
                .lineLimit(1)

            Spacer().frame(minWidth: 8)

            Text(entry.phaseLabel)
                .font(.system(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if entry.retryCount > 0 {
                Text("\(entry.retryCount)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                    .padding(.leading, 6)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    // MARK: - Stuck

    private var stuckSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("STUCK", count: stateModel.stuckEntries.count)

            if stateModel.stuckEntries.isEmpty {
                emptyRow("None")
            } else {
                ForEach(stateModel.stuckEntries) { entry in
                    stuckRow(entry)
                }
            }
        }
    }

    private func stuckRow(_ entry: StateEntry) -> some View {
        HStack(spacing: 0) {
            Circle()
                .fill(Color.red)
                .frame(width: 6, height: 6)
                .padding(.trailing, 8)

            Text(entry.displayLabel)
                .font(.system(.body, design: .monospaced).bold())
                .lineLimit(1)

            Spacer().frame(minWidth: 8)

            Text(entry.stuckReason)
                .font(.system(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Button {
                stateModel.resetEntry(entry.id)
            } label: {
                Text("Reset")
                    .font(.system(.caption))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.borderless)
            .padding(.leading, 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                showClearConfirm = true
            } label: {
                Text("Clear All")
                    .font(.system(.caption))
            }
            .buttonStyle(.borderless)

            Spacer()

            SettingsButton()

            Button {
                NSApp.terminate(nil)
            } label: {
                Text("Quit")
                    .font(.system(.caption))
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, count: Int) -> some View {
        Text("\(title) (\(count))")
            .font(.system(.caption))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
    }
}

// MARK: - Settings Button

@available(macOS 14.0, *)
private struct SettingsButton14: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            openSettings()
        } label: {
            Text("Settings")
                .font(.system(.caption))
        }
        .buttonStyle(.borderless)
    }
}

private struct SettingsButton: View {
    var body: some View {
        if #available(macOS 14.0, *) {
            SettingsButton14()
        } else {
            Button {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Text("Settings")
                    .font(.system(.caption))
            }
            .buttonStyle(.borderless)
        }
    }
}
