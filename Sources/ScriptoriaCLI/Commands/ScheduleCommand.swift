import ArgumentParser
import Foundation
import ScriptoriaCore

struct ScheduleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "schedule",
        abstract: "Manage scheduled tasks",
        subcommands: [
            ScheduleList.self,
            ScheduleAdd.self,
            ScheduleRemove.self,
            ScheduleEnable.self,
            ScheduleDisable.self,
        ],
        defaultSubcommand: ScheduleList.self
    )
}

// MARK: - List

struct ScheduleList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all schedules"
    )

    func run() async throws {
        let scheduleStore = ScheduleStore.fromConfig()
        let scriptStore = ScriptStore.fromConfig()
        try await scheduleStore.load()
        try await scriptStore.load()

        let schedules = scheduleStore.all()

        if schedules.isEmpty {
            print("No scheduled tasks.")
            return
        }

        print("\n  SCHEDULED TASKS — \(schedules.count)\n")
        print(String(repeating: "─", count: 66))

        for schedule in schedules {
            let script = scriptStore.get(id: schedule.scriptId)
            let title = script?.title ?? "Unknown"
            let enabled = schedule.isEnabled ? "●" : "○"
            let color = schedule.isEnabled ? "ON " : "OFF"
            let shortId = String(schedule.id.uuidString.prefix(8))

            print("  \(enabled) [\(color)] \(title)")
            print("         \(schedule.type.displayText)")
            if let next = schedule.nextRunAt {
                print("         Next: \(next.formatted(.dateTime))")
            }
            let installed = LaunchdHelper.isInstalled(scheduleId: schedule.id) ? "installed" : "not installed"
            print("         \(shortId) · launchd: \(installed)")
            print(String(repeating: "─", count: 66))
        }
        print()
    }
}

// MARK: - Add

struct ScheduleAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a schedule for a script"
    )

    @Argument(help: "Script title or ID")
    var script: String

    @Option(name: .long, help: "Interval in minutes (e.g. 30)")
    var every: Int?

    @Option(name: .long, help: "Daily time (HH:MM)")
    var daily: String?

    @Option(name: .long, help: "Weekly days + time (e.g. 'mon,wed,fri@09:00')")
    var weekly: String?

    func run() async throws {
        let scriptStore = ScriptStore.fromConfig()
        let scheduleStore = ScheduleStore.fromConfig()
        try await scriptStore.load()
        try await scheduleStore.load()

        // Find script
        let found: Script?
        if let uuid = UUID(uuidString: script) {
            found = scriptStore.get(id: uuid)
        } else {
            found = scriptStore.get(title: script)
        }

        guard let found else {
            print("❌ Script not found: \(script)")
            throw ExitCode.failure
        }

        // Parse schedule type
        let scheduleType: ScheduleType

        if let every {
            scheduleType = .interval(TimeInterval(every * 60))
        } else if let daily {
            let parts = daily.split(separator: ":")
            guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else {
                print("❌ Invalid time format. Use HH:MM (e.g. 09:30)")
                throw ExitCode.failure
            }
            scheduleType = .daily(hour: h, minute: m)
        } else if let weekly {
            let components = weekly.split(separator: "@")
            guard components.count == 2 else {
                print("❌ Invalid format. Use 'mon,wed,fri@09:00'")
                throw ExitCode.failure
            }
            let dayMap = ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7]
            let days = components[0].split(separator: ",").compactMap { dayMap[String($0).lowercased()] }
            let timeParts = components[1].split(separator: ":")
            guard timeParts.count == 2, let h = Int(timeParts[0]), let m = Int(timeParts[1]) else {
                print("❌ Invalid time format.")
                throw ExitCode.failure
            }
            scheduleType = .weekly(weekdays: days, hour: h, minute: m)
        } else {
            print("❌ Specify one of: --every <minutes>, --daily HH:MM, --weekly 'mon,fri@09:00'")
            throw ExitCode.failure
        }

        let schedule = Schedule(scriptId: found.id, type: scheduleType)

        try await scheduleStore.add(schedule)
        try await scheduleStore.activate(schedule)

        print("✅ Scheduled: \(found.title)")
        print("   \(scheduleType.displayText)")
        if let next = ScheduleStore.computeNextRun(for: scheduleType) {
            print("   Next run: \(next.formatted(.dateTime))")
        }
    }
}

// MARK: - Remove

struct ScheduleRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a schedule"
    )

    @Argument(help: "Schedule ID (short or full UUID)")
    var scheduleId: String

    func run() async throws {
        let store = ScheduleStore.fromConfig()
        try await store.load()

        // Find by prefix match
        let match = store.all().first { $0.id.uuidString.lowercased().hasPrefix(scheduleId.lowercased()) }

        guard let match else {
            print("❌ Schedule not found: \(scheduleId)")
            throw ExitCode.failure
        }

        try await store.deactivate(match)
        try await store.remove(id: match.id)
        print("🗑  Removed schedule \(String(match.id.uuidString.prefix(8)))")
    }
}

// MARK: - Enable / Disable

struct ScheduleEnable: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enable",
        abstract: "Enable a schedule"
    )

    @Argument(help: "Schedule ID")
    var scheduleId: String

    func run() async throws {
        let store = ScheduleStore.fromConfig()
        try await store.load()

        guard let match = store.all().first(where: { $0.id.uuidString.lowercased().hasPrefix(scheduleId.lowercased()) }) else {
            print("❌ Schedule not found")
            throw ExitCode.failure
        }

        try await store.activate(match)
        print("✅ Enabled schedule \(String(match.id.uuidString.prefix(8)))")
    }
}

struct ScheduleDisable: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disable",
        abstract: "Disable a schedule"
    )

    @Argument(help: "Schedule ID")
    var scheduleId: String

    func run() async throws {
        let store = ScheduleStore.fromConfig()
        try await store.load()

        guard let match = store.all().first(where: { $0.id.uuidString.lowercased().hasPrefix(scheduleId.lowercased()) }) else {
            print("❌ Schedule not found")
            throw ExitCode.failure
        }

        try await store.deactivate(match)
        print("⏸  Disabled schedule \(String(match.id.uuidString.prefix(8)))")
    }
}
