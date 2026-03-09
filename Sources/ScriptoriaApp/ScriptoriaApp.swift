import SwiftUI
import ScriptoriaCore

@main
struct ScriptoriaApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // Menu bar (primary interface)
        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(appState)
        } label: {
            Label {
                Text("Scriptoria")
            } icon: {
                Image(systemName: appState.isRunning ? "terminal.fill" : "terminal")
                    .symbolEffect(.pulse, isActive: appState.isRunning)
            }
        }
        .menuBarExtraStyle(.window)

        // Main window
        Window("Scriptoria", id: "main") {
            Group {
                if appState.needsOnboarding {
                    OnboardingView(isPresented: $appState.needsOnboarding)
                        .environmentObject(appState)
                } else {
                    MainWindowView()
                        .environmentObject(appState)
                        .frame(minWidth: 800, minHeight: 520)
                }
            }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: appState.needsOnboarding ? 520 : 1000,
                      height: appState.needsOnboarding ? 480 : 660)

        // Settings
        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
