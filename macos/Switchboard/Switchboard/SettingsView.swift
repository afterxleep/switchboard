import SwiftUI

struct SettingsView: View {
    @State private var githubToken = ""
    @State private var githubRepo = ""
    @State private var linearAPIKey = ""
    @State private var linearTeamSlug = ""
    @State private var repoPath = ""
    @State private var saveStatus = ""

    private let configURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".flowdeck-daemon/config.json")
    }()

    var body: some View {
        Form {
            Section("GitHub") {
                SecureField("GitHub Token", text: $githubToken, prompt: Text("ghp_..."))
                TextField("GitHub Repo", text: $githubRepo, prompt: Text("owner/repo"))
            }

            Section("Linear") {
                SecureField("Linear API Key", text: $linearAPIKey, prompt: Text("lin_api_..."))
                TextField("Linear Team Slug", text: $linearTeamSlug, prompt: Text("DB"))
            }

            Section("Paths") {
                TextField("Repo Path", text: $repoPath, prompt: Text("~/Developer/myrepo"))
            }

            HStack {
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)

                if !saveStatus.isEmpty {
                    Text(saveStatus)
                        .font(.caption)
                        .foregroundStyle(saveStatus.contains("Error") ? .red : .green)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 340)
        .onAppear { load() }
    }

    private func load() {
        guard let data = try? Data(contentsOf: configURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return
        }
        githubToken = dict["GITHUB_TOKEN"] ?? ""
        githubRepo = dict["GITHUB_REPO"] ?? ""
        linearAPIKey = dict["LINEAR_API_KEY"] ?? ""
        linearTeamSlug = dict["LINEAR_TEAM_SLUG"] ?? ""
        repoPath = dict["REPO_PATH"] ?? ""
    }

    private func save() {
        let config: [String: String] = [
            "GITHUB_TOKEN": githubToken,
            "GITHUB_REPO": githubRepo,
            "LINEAR_API_KEY": linearAPIKey,
            "LINEAR_TEAM_SLUG": linearTeamSlug,
            "REPO_PATH": repoPath
        ]

        do {
            let dir = configURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: configURL)
        } catch {
            saveStatus = "Error: \(error.localizedDescription)"
            return
        }

        updatePlistEnvVars(config)
        restartDaemon()

        saveStatus = "Saved & daemon restarted"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            saveStatus = ""
        }
    }

    private func updatePlistEnvVars(_ config: [String: String]) {
        let plistPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.flowdeck.daemon.plist").path
        guard FileManager.default.fileExists(atPath: plistPath) else { return }

        for (key, value) in config {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/libexec/PlistBuddy")
            process.arguments = ["-c", "Set :EnvironmentVariables:\(key) \(value)", plistPath]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let addProcess = Process()
                addProcess.executableURL = URL(fileURLWithPath: "/usr/libexec/PlistBuddy")
                addProcess.arguments = ["-c", "Add :EnvironmentVariables:\(key) string \(value)", plistPath]
                addProcess.standardOutput = Pipe()
                addProcess.standardError = Pipe()
                try? addProcess.run()
                addProcess.waitUntilExit()
            }
        }
    }

    private func restartDaemon() {
        let plistPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.flowdeck.daemon.plist").path

        let unload = Process()
        unload.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        unload.arguments = ["unload", plistPath]
        unload.standardOutput = Pipe()
        unload.standardError = Pipe()
        try? unload.run()
        unload.waitUntilExit()

        let load = Process()
        load.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        load.arguments = ["load", plistPath]
        load.standardOutput = Pipe()
        load.standardError = Pipe()
        try? load.run()
        load.waitUntilExit()
    }
}
