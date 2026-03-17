import Foundation
import SwiftUI

struct StateEntry: Identifiable {
    let id: String
    let status: String
    let agentPhase: String
    let retryCount: Int
    let consecutiveCIFailures: Int
    let prNumber: Int?
    let details: String

    var isInProgress: Bool {
        let activeStatus = status == "inFlight" ||
            (status == "pending" && agentPhase != "done" && agentPhase != "waitingOnReview")
        return activeStatus && retryCount < 3 && consecutiveCIFailures < 10
    }

    var isStuck: Bool {
        retryCount >= 3 || consecutiveCIFailures >= 10
    }

    var displayLabel: String {
        Self.formatId(id)
    }

    var phaseLabel: String {
        switch agentPhase {
        case "coding": return "coding"
        case "addressingFeedback": return "feedback"
        case "ciBlocked": return "CI blocked"
        case "waitingOnReview": return "waiting"
        case "done": return "done"
        case "": return status
        default: return agentPhase
        }
    }

    var stuckReason: String {
        if retryCount >= 3 { return "retried \(retryCount)x" }
        if consecutiveCIFailures >= 10 { return "CI failing" }
        return ""
    }

    private static func formatId(_ raw: String) -> String {
        // "gh:pr:149:thread:PRRT_xxx" → "PR #149 (thread)"
        if raw.hasPrefix("gh:pr:") {
            let rest = raw.dropFirst("gh:pr:".count)
            let parts = rest.split(separator: ":", maxSplits: 2)
            let prNum = parts.first.map(String.init) ?? raw
            if parts.count > 1 && parts[1] == "thread" {
                return "PR #\(prNum) (thread)"
            }
            return "PR #\(prNum)"
        }
        // "linear:DB-165" → "DB-165"
        if raw.hasPrefix("linear:") {
            return String(raw.dropFirst("linear:".count))
        }
        // Fallback: strip any "prefix:" to get meaningful part
        if let colonIdx = raw.firstIndex(of: ":") {
            return String(raw[raw.index(after: colonIdx)...])
        }
        return raw
    }
}

enum DaemonStatus {
    case running, stopped, unknown

    var label: String {
        switch self {
        case .running: return "Running"
        case .stopped: return "Stopped"
        case .unknown: return "Unknown"
        }
    }

    var color: Color {
        switch self {
        case .running: return .green
        case .stopped: return .yellow
        case .unknown: return .gray
        }
    }
}

@MainActor
final class DaemonStateModel: ObservableObject {
    @Published var entries: [StateEntry] = []
    @Published var daemonStatus: DaemonStatus = .unknown

    private var timer: Timer?
    private let dbPath: String

    var inProgressEntries: [StateEntry] {
        entries.filter { $0.isInProgress }
    }

    var stuckEntries: [StateEntry] {
        entries.filter { $0.isStuck }
    }

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.dbPath = "\(home)/.flowdeck-daemon/state.db"
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
        process.standardOutput = Pipe()
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
        let query = "SELECT id, status, agent_phase, retry_count, consecutive_ci_failures, pr_number, details FROM state_entries WHERE status != 'done'"
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
            let ciFailures = Int(sqlite3_column_int(stmt, 4))
            let prNumber: Int? = sqlite3_column_type(stmt, 5) != SQLITE_NULL
                ? Int(sqlite3_column_int(stmt, 5)) : nil
            let details = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""
            result.append(StateEntry(
                id: id, status: status, agentPhase: phase,
                retryCount: retryCount, consecutiveCIFailures: ciFailures,
                prNumber: prNumber, details: details
            ))
        }
        entries = result
    }

    func resetEntry(_ id: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/Users/afterxleep/bin/flowdeck-daemon")
        process.arguments = ["reset", id]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        refresh()
    }

    func clearAll() {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "DELETE FROM state_entries", nil, nil, nil)
        refresh()
    }

    func toggleDaemon() {
        let plistPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.flowdeck.daemon.plist").path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = daemonStatus == .running
            ? ["unload", plistPath]
            : ["load", plistPath]
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
