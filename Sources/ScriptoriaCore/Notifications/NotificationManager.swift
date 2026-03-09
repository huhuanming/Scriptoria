import Foundation
import UserNotifications

/// Manages local notifications for script execution results
public final class NotificationManager: Sendable {
    public static let shared = NotificationManager()

    private init() {}

    /// Request notification permission
    public func requestPermission() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    /// Send a notification about a script run result
    public func notifyRunComplete(_ run: ScriptRun) async {
        let content = UNMutableNotificationContent()

        switch run.status {
        case .success:
            content.title = "✅ \(run.scriptTitle)"
            content.body = "Script completed successfully"
        case .failure:
            content.title = "❌ \(run.scriptTitle)"
            content.body = run.errorOutput.isEmpty
                ? "Script failed with exit code \(run.exitCode ?? -1)"
                : String(run.errorOutput.prefix(200))
        case .cancelled:
            content.title = "⏹ \(run.scriptTitle)"
            content.body = "Script was cancelled"
        case .running:
            return
        }

        if let duration = run.duration {
            content.body += " (\(String(format: "%.1f", duration))s)"
        }

        content.sound = .default
        content.userInfo = [
            "scriptId": run.scriptId.uuidString,
            "runId": run.id.uuidString,
        ]

        let request = UNNotificationRequest(
            identifier: run.id.uuidString,
            content: content,
            trigger: nil
        )

        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Send a reminder notification for a scheduled script
    public func notifyScheduledRun(scriptTitle: String, scriptId: UUID) async {
        let content = UNMutableNotificationContent()
        content.title = "🔄 Scriptoria"
        content.body = "Running scheduled script: \(scriptTitle)"
        content.sound = .default
        content.userInfo = ["scriptId": scriptId.uuidString]

        let request = UNNotificationRequest(
            identifier: "schedule-\(scriptId.uuidString)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )

        try? await UNUserNotificationCenter.current().add(request)
    }
}
