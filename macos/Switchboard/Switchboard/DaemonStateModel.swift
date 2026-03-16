import Foundation
import SwiftUI

struct StateEntry: Identifiable {
    let id: String
    let status: String
    let agentPhase: String
    let retryCount: Int

    var isActive: Bool {
        status == "inFlight" ||
        (status == "pending" && agentPhase != "done" && agentPhase != "waitingOnReview")
    }

    var isParked: Bool {
        retryCount >= 3
    }

    var displayLabel: String {
        if agentPhase == "waitingOnReview" || agentPhase.hasPrefix("pr") {
            return "[\(id)] \(agentPhase)"
        }
        return "[\(id)] \(agentPhase.isEmpty ? status : agentPhase)"
    }
}

enum DaemonStatus: String {
    case running = "Running"
    case stopped = "Stopped"
    case unknown = "Unknown"
}

@MainActor
final class DaemonStateModel: ObservableObject {
    @Published var entries: [StateEntry] = []
    @Published var daemonStatus: DaemonStatus = .unknown

    private var timer: Timer?
    private let dbPath: String
    private let configPath: String

    var activeEntries: [StateEntry] {
        entries.filter { $0.isActive && !$0.isParked }
    }

    var parkedEntries: [StateEntry] {
        entries.filter { $0.isParked }
    }

    var daemonStatusColor: Color {
        switch daemonStatus {
        case .running: return .green
        case .stopped: return .red
        case .unknown: return .gray
        }
    }

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.dbPath = "\(home)/.flowdeck-daemon/state.db"
        self.configPath = "\(home)/.flowdeck-daemon/config.json"
        startPolling()
    }

    func startPolling() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    func refresh() {
        checkDaemonStatus()
        readStateDB()
    }

    private func checkDaemonStatus() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", "flowdeck-daemon"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            daemonStatus = process.terminationStatus == 0 ? .running : .stopped
        } catch {
            daemonStatus = .unknown
        }
    }

    private func readStateDB() {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            entries = []
            return
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let query = "SELECT id, status, agent_phase, retry_count FROM state_entries WHERE status != 'done'"
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            entries = []
            return
        }
        defer { sqlite3_finalize(stmt) }

        var result: [StateEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let status = String(cString: sqlite3_column_text(stmt, 1))
            let phase = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let retryCount = Int(sqlite3_column_int(stmt, 3))
            result.append(StateEntry(id: id, status: status, agentPhase: phase, retryCount: retryCount))
        }
        entries = result
    }

    func resetEntry(_ id: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["flowdeck-daemon", "reset", id]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        refresh()
    }

    func toggleDaemon() {
        let plistPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.flowdeck.daemon.plist").path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")

        if daemonStatus == .running {
            process.arguments = ["unload", plistPath]
        } else {
            process.arguments = ["load", plistPath]
        }
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refresh()
        }
    }

    deinit {
        timer?.invalidate()
    }
}
