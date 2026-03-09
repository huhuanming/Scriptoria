import SwiftUI
import ScriptoriaCore

/// Settings window
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var dataDirectory: String = ""
    @State private var notifyOnCompletion: Bool = true
    @State private var showRunningIndicator: Bool = true
    @State private var cliInstallStatus: CLIInstallStatus = .unknown

    enum CLIInstallStatus: Equatable {
        case unknown, installed, notInstalled, justInstalled, failed(String)
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            storageTab
                .tabItem {
                    Label("Storage", systemImage: "externaldrive")
                }

            aboutTab
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 520, height: 320)
        .onAppear {
            dataDirectory = appState.config.dataDirectory
            notifyOnCompletion = appState.config.notifyOnCompletion
            showRunningIndicator = appState.config.showRunningIndicator
        }
    }

    var generalTab: some View {
        Form {
            Section {
                Toggle("Send notification when script finishes", isOn: $notifyOnCompletion)
                    .onChange(of: notifyOnCompletion) { _, newValue in
                        var config = appState.config
                        config.notifyOnCompletion = newValue
                        appState.updateConfig(config)
                    }

                Toggle("Animate menu bar icon when running", isOn: $showRunningIndicator)
                    .onChange(of: showRunningIndicator) { _, newValue in
                        var config = appState.config
                        config.showRunningIndicator = newValue
                        appState.updateConfig(config)
                    }
            }

            Section("Shell Command") {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Install 'scriptoria' command in PATH")
                            .font(.callout)
                        Text("Creates a symlink at /usr/local/bin/scriptoria")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    switch cliInstallStatus {
                    case .installed:
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.successColor)
                    case .justInstalled:
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.successColor)
                    case .failed(let msg):
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(Theme.failureColor)
                    default:
                        EmptyView()
                    }
                    if cliInstallStatus != .installed && cliInstallStatus != .justInstalled {
                        Button("Install") {
                            installCLI()
                        }
                    } else {
                        Button("Uninstall") {
                            uninstallCLI()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { checkCLIInstalled() }
    }

    var storageTab: some View {
        Form {
            Section("Data Directory") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("All Scriptoria data is stored in this directory:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.accent)
                        Text(dataDirectory)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))

                    HStack(spacing: 8) {
                        Button {
                            setDataDirectory(Config.defaultDataDirectory)
                        } label: {
                            Label("Local", systemImage: "internaldrive")
                        }
                        .disabled(dataDirectory == Config.defaultDataDirectory)

                        Button {
                            setDataDirectory(Config.iCloudDataDirectory)
                        } label: {
                            Label("iCloud", systemImage: "icloud")
                        }
                        .disabled(dataDirectory == Config.iCloudDataDirectory)

                        Button {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            panel.canCreateDirectories = true
                            panel.prompt = "Select"
                            panel.message = "Choose a directory for Scriptoria data"
                            if panel.runModal() == .OK, let url = panel.url {
                                setDataDirectory(url.path)
                            }
                        } label: {
                            Label("Custom...", systemImage: "folder.badge.gearshape")
                        }

                        Spacer()

                        Button {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dataDirectory)
                        } label: {
                            Label("Reveal", systemImage: "arrow.right.circle")
                        }
                    }
                    .font(.caption)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Stored in this directory:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("db/scriptoria.db, scripts/")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .formStyle(.grouped)
    }

    var aboutTab: some View {
        VStack(spacing: 12) {
            Spacer()

            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Theme.accentGradient.opacity(0.15))
                    .frame(width: 64, height: 64)
                Image(systemName: "terminal.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.accent)
            }

            Text("Scriptoria")
                .font(.title2.weight(.bold))

            Text("Version 0.1.0")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Your automation script workshop")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - CLI Install

    private static let symlinkPath = "/usr/local/bin/scriptoria"

    private func checkCLIInstalled() {
        let fm = FileManager.default
        let path = Self.symlinkPath
        if fm.fileExists(atPath: path) {
            // Verify it's a valid symlink (not a broken one)
            if let _ = try? fm.destinationOfSymbolicLink(atPath: path) {
                cliInstallStatus = .installed
            } else {
                cliInstallStatus = .installed
            }
        } else {
            cliInstallStatus = .notInstalled
        }
    }

    private func findCLIBinary() -> String? {
        // 1. Inside app bundle (for .app distribution)
        if let bundleURL = Bundle.main.executableURL?.deletingLastPathComponent() {
            let bundled = bundleURL.appendingPathComponent("scriptoria").path
            if FileManager.default.fileExists(atPath: bundled) {
                return bundled
            }
        }
        // 2. Swift build directory (development)
        let devPath = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("scriptoria").path
        if FileManager.default.fileExists(atPath: devPath) {
            return devPath
        }
        // 3. Common build paths
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let buildPaths = [
            "\(home)/.swiftpm/bin/scriptoria",
            "\(home)/.local/bin/scriptoria",
        ]
        for p in buildPaths {
            if FileManager.default.fileExists(atPath: p) {
                return p
            }
        }
        return nil
    }

    private func installCLI() {
        guard let cliPath = findCLIBinary() else {
            cliInstallStatus = .failed("CLI binary not found")
            return
        }

        let targetDir = "/usr/local/bin"
        let symlink = Self.symlinkPath

        // Use AppleScript to run with admin privileges
        let script = """
        do shell script "mkdir -p \(targetDir) && ln -sf \(cliPath) \(symlink)" with administrator privileges
        """
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
            if let error {
                let msg = error[NSAppleScript.errorMessage] as? String ?? "Permission denied"
                cliInstallStatus = .failed(msg)
            } else {
                cliInstallStatus = .justInstalled
            }
        }
    }

    private func uninstallCLI() {
        let symlink = Self.symlinkPath
        let script = """
        do shell script "rm -f \(symlink)" with administrator privileges
        """
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
            if error == nil {
                cliInstallStatus = .notInstalled
            }
        }
    }

    private func setDataDirectory(_ path: String) {
        let oldDir = appState.config.dataDirectory
        dataDirectory = path

        // Migrate data from old directory to new one
        if oldDir != path {
            try? Config.migrateDataDirectory(from: oldDir, to: path)
        }

        var config = appState.config
        config.dataDirectory = path
        appState.updateConfig(config)
        // Reload data from new location
        Task {
            await appState.reloadWithConfig(config)
        }
    }
}
