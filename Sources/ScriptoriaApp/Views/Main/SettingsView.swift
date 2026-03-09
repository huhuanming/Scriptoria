import SwiftUI
import ScriptoriaCore

/// Settings window
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var dataDirectory: String = ""
    @State private var notifyOnCompletion: Bool = true
    @State private var showRunningIndicator: Bool = true
    @State private var showSaveConfirmation = false

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
        .frame(width: 500, height: 300)
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
            Section {
                LabeledContent("Data Directory") {
                    VStack(alignment: .trailing, spacing: 8) {
                        Text(dataDirectory)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)

                        HStack(spacing: 8) {
                            Button("iCloud") {
                                dataDirectory = Config.iCloudDataDirectory
                                saveDataDirectory()
                            }
                            .help("Store in iCloud Drive for sync")

                            Button("Local") {
                                dataDirectory = Config.defaultDataDirectory
                                saveDataDirectory()
                            }
                            .help("Store locally")

                            Button("Custom...") {
                                let panel = NSOpenPanel()
                                panel.canChooseFiles = false
                                panel.canChooseDirectories = true
                                panel.canCreateDirectories = true
                                if panel.runModal() == .OK, let url = panel.url {
                                    dataDirectory = url.path
                                    saveDataDirectory()
                                }
                            }
                        }
                    }
                }
            }

            Section {
                LabeledContent("Config File") {
                    Text(Config.configFilePath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
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

    private func saveDataDirectory() {
        try? FileManager.default.createDirectory(
            atPath: dataDirectory,
            withIntermediateDirectories: true
        )
        var config = appState.config
        config.dataDirectory = dataDirectory
        appState.updateConfig(config)
    }
}
