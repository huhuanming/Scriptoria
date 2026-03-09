import SwiftUI
import ScriptoriaCore

/// First-launch onboarding: asks user to pick a data directory
struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    @State private var selectedPath: String = Config.defaultDataDirectory
    @State private var selectedOption: StorageOption = .local

    enum StorageOption: String, CaseIterable {
        case local = "Local"
        case custom = "Custom"
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 32)

            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(Theme.accentGradient.opacity(0.15))
                    .frame(width: 72, height: 72)
                Image(systemName: "terminal.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(Theme.accent)
            }

            Spacer().frame(height: 16)

            Text("Welcome to Scriptoria")
                .font(.title.weight(.bold))

            Text("Your automation script workshop")
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            Spacer().frame(height: 28)

            // Directory selection
            VStack(alignment: .leading, spacing: 14) {
                Text("Where should Scriptoria store your scripts and data?")
                    .font(.callout)

                VStack(spacing: 8) {
                    optionRow(.local, icon: "internaldrive", title: "Local", subtitle: Config.defaultDataDirectory)
                    optionRow(.custom, icon: "folder.badge.gearshape", title: "Custom Location", subtitle: selectedOption == .custom ? selectedPath : "Choose a directory...")
                }
            }
            .padding(.horizontal, 36)

            Spacer()

            Divider()

            // Footer
            HStack {
                Text("You can change this later in Settings")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Get Started") {
                    Task {
                        await completeOnboarding()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(20)
        }
        .frame(width: 520, height: 460)
    }

    private func optionRow(_ option: StorageOption, icon: String, title: String, subtitle: String) -> some View {
        Button {
            if option == .custom {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.canCreateDirectories = true
                panel.prompt = "Select"
                panel.message = "Choose a directory for Scriptoria data"
                if panel.runModal() == .OK, let url = panel.url {
                    selectedPath = url.path
                    selectedOption = .custom
                }
            } else {
                selectedOption = option
                selectedPath = Config.defaultDataDirectory
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(selectedOption == option ? Theme.accent : .secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                if selectedOption == option {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selectedOption == option ? AnyShapeStyle(Theme.accent.opacity(0.08)) : AnyShapeStyle(.quaternary.opacity(0.3)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selectedOption == option ? Theme.accent.opacity(0.3) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func completeOnboarding() async {
        // Save config
        let config = Config(dataDirectory: selectedPath)
        try? config.save()

        // Create example script
        await createExampleScript(in: selectedPath)

        // If user chose a non-default directory, clean up any leftover data files in ~/.scriptoria/
        // (pointer.json is kept since it lives there permanently)
        if selectedPath != Config.defaultDataDirectory {
            let defaultDir = Config.defaultDataDirectory
            let fm = FileManager.default
            // Clean up db/ and scripts/ subdirectories, plus any legacy root files
            for dir in ["db", "scripts"] {
                try? fm.removeItem(atPath: "\(defaultDir)/\(dir)")
            }
            let legacyFiles = ["scriptoria.db", "scriptoria.db-wal", "scriptoria.db-shm"]
            for file in legacyFiles {
                try? fm.removeItem(atPath: "\(defaultDir)/\(file)")
            }
        }

        // Reload app state
        appState.needsOnboarding = false
        await appState.reloadWithConfig(config)

        // Close onboarding, open main window
        dismissWindow(id: "onboarding")
        openWindow(id: "main")
    }

    private func createExampleScript(in directory: String) async {
        let scriptsDir = "\(directory)/scripts"
        try? FileManager.default.createDirectory(
            atPath: scriptsDir, withIntermediateDirectories: true
        )

        let scriptPath = "\(scriptsDir)/hello-world.sh"
        let scriptContent = """
        #!/bin/bash
        # Scriptoria Example Script
        # This is a simple hello world script to get you started.

        echo "=============================="
        echo "  Hello from Scriptoria!"
        echo "=============================="
        echo ""
        echo "System: $(uname -s) $(uname -m)"
        echo "User:   $(whoami)"
        echo "Date:   $(date)"
        echo "Shell:  $SHELL"
        echo ""
        echo "Your automation workshop is ready."
        echo "Add your own scripts with: scriptoria add <path>"
        """

        try? scriptContent.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptPath
        )

        let script = Script(
            title: "Hello World",
            description: "Welcome example script - feel free to remove",
            path: scriptPath,
            interpreter: .bash,
            tags: ["example"]
        )

        let store = ScriptStore(baseDirectory: directory)
        try? await store.load()
        try? await store.add(script)
    }
}
