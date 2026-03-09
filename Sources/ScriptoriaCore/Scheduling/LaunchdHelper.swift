import Foundation

/// Generates and manages launchd plist files for scheduled scripts
public final class LaunchdHelper: Sendable {
    private static let plistPrefix = "com.scriptoria.task"

    private static var launchAgentsDir: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/LaunchAgents"
    }

    /// Generate and install a launchd plist for a schedule
    public static func install(schedule: Schedule, cliPath: String) throws {
        let plistName = "\(plistPrefix).\(schedule.id.uuidString)"
        let plistPath = "\(launchAgentsDir)/\(plistName).plist"

        var plist: [String: Any] = [
            "Label": plistName,
            "ProgramArguments": [cliPath, "run", "--id", schedule.scriptId.uuidString, "--scheduled"],
            "StandardOutPath": "/tmp/scriptoria-\(schedule.id.uuidString).log",
            "StandardErrorPath": "/tmp/scriptoria-\(schedule.id.uuidString).err",
        ]

        switch schedule.type {
        case .interval(let seconds):
            plist["StartInterval"] = Int(seconds)

        case .daily(let hour, let minute):
            plist["StartCalendarInterval"] = [
                "Hour": hour,
                "Minute": minute,
            ]

        case .weekly(let weekdays, let hour, let minute):
            plist["StartCalendarInterval"] = weekdays.map { day in
                [
                    "Weekday": day,
                    "Hour": hour,
                    "Minute": minute,
                ] as [String: Int]
            }

        case .cron:
            // For cron expressions, we'd need to convert to calendar intervals
            // For now, fall back to a reasonable interval
            plist["StartInterval"] = 3600
        }

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: URL(fileURLWithPath: plistPath))

        // Load the agent
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["load", plistPath]
        try process.run()
        process.waitUntilExit()
    }

    /// Uninstall a launchd plist
    public static func uninstall(scheduleId: UUID) throws {
        let plistName = "\(plistPrefix).\(scheduleId.uuidString)"
        let plistPath = "\(launchAgentsDir)/\(plistName).plist"

        // Unload first
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["unload", plistPath]
        try process.run()
        process.waitUntilExit()

        // Remove file
        try FileManager.default.removeItem(atPath: plistPath)
    }

    /// Check if a schedule is currently installed
    public static func isInstalled(scheduleId: UUID) -> Bool {
        let plistName = "\(plistPrefix).\(scheduleId.uuidString)"
        let plistPath = "\(launchAgentsDir)/\(plistName).plist"
        return FileManager.default.fileExists(atPath: plistPath)
    }
}
