import SwiftUI
import ScriptoriaCore

@main
struct ScriptoriaApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(ScriptoriaAppDelegate.self) var appDelegate

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

        // Onboarding window (first launch only, auto-opens)
        Window("Welcome to Scriptoria", id: "onboarding") {
            OnboardingView()
                .environmentObject(appState)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .defaultLaunchBehavior(appState.needsOnboarding ? .presented : .suppressed)

        // Main window
        Window("Scriptoria", id: "main") {
            MainWindowView()
                .environmentObject(appState)
                .frame(minWidth: 800, minHeight: 520)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1000, height: 660)
        .defaultLaunchBehavior(.suppressed)

        // Settings
        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
