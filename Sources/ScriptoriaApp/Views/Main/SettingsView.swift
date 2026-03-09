import SwiftUI
import ScriptoriaCore

/// Settings window
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var dataDirectory: String = ""
    @State private var notifyOnCompletion: Bool = true
    @State private var showRunningIndicator: Bool = true

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
        }
        .formStyle(.grouped)
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
                    Text("config.json, scripts.json, schedules.json, history/")
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

    private func setDataDirectory(_ path: String) {
        dataDirectory = path
        var config = appState.config
        config.dataDirectory = path
        appState.updateConfig(config)
        // Reload data from new location
        Task {
            await appState.reloadWithConfig(config)
        }
    }
}
