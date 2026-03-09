import AppKit
import SwiftUI

/// App delegate to handle auto-opening the onboarding window on first launch
final class ScriptoriaAppDelegate: NSObject, NSApplicationDelegate {
    var needsOnboarding: Bool = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if needsOnboarding {
            // Small delay to ensure window scene is registered
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}
