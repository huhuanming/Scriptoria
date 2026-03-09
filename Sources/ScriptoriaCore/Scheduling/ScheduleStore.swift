import Foundation

/// Central store for managing schedules
public final class ScheduleStore: @unchecked Sendable {
    private let storage: StorageManager
    private var schedules: [Schedule] = []
    private let lock = NSLock()

    public init(baseDirectory: String? = nil) {
        self.storage = StorageManager(baseDirectory: baseDirectory)
    }

    public convenience init(config: Config) {
        self.init(baseDirectory: config.dataDirectory)
    }

    public static func fromConfig() -> ScheduleStore {
        ScheduleStore(config: Config.load())
    }

    // MARK: - Lifecycle

    public func load() async throws {
        try await storage.ensureDirectories()
        let path = await storage.schedulesFile
        do {
            let loaded = try await storage.read([Schedule].self, from: path)
            lock.withLock { schedules = loaded }
        } catch {
            lock.withLock { schedules = [] }
        }
    }

    public func save() async throws {
        let current = lock.withLock { schedules }
        let path = await storage.schedulesFile
        try await storage.write(current, to: path)
    }

    // MARK: - CRUD

    public func all() -> [Schedule] {
        lock.withLock { schedules }
    }

    public func get(id: UUID) -> Schedule? {
        lock.withLock { schedules.first { $0.id == id } }
    }

    public func forScript(id: UUID) -> [Schedule] {
        lock.withLock { schedules.filter { $0.scriptId == id } }
    }

    @discardableResult
    public func add(_ schedule: Schedule) async throws -> Schedule {
        lock.withLock { schedules.append(schedule) }
        try await save()
        return schedule
    }

    public func update(_ schedule: Schedule) async throws {
        lock.withLock {
            if let index = schedules.firstIndex(where: { $0.id == schedule.id }) {
                schedules[index] = schedule
            }
        }
        try await save()
    }

    public func remove(id: UUID) async throws {
        lock.withLock { schedules.removeAll { $0.id == id } }
        try await save()
    }

    public func removeForScript(scriptId: UUID) async throws {
        let toRemove = lock.withLock { schedules.filter { $0.scriptId == scriptId } }
        for schedule in toRemove {
            if LaunchdHelper.isInstalled(scheduleId: schedule.id) {
                try? LaunchdHelper.uninstall(scheduleId: schedule.id)
            }
        }
        lock.withLock { schedules.removeAll { $0.scriptId == scriptId } }
        try await save()
    }

    // MARK: - launchd integration

    /// Install a schedule into launchd
    public func activate(_ schedule: Schedule) async throws {
        let cliPath = ScheduleStore.resolveCliPath()
        try LaunchdHelper.install(schedule: schedule, cliPath: cliPath)
        var updated = schedule
        updated.isEnabled = true
        updated.nextRunAt = ScheduleStore.computeNextRun(for: schedule.type)
        try await update(updated)
    }

    /// Uninstall a schedule from launchd
    public func deactivate(_ schedule: Schedule) async throws {
        if LaunchdHelper.isInstalled(scheduleId: schedule.id) {
            try LaunchdHelper.uninstall(scheduleId: schedule.id)
        }
        var updated = schedule
        updated.isEnabled = false
        updated.nextRunAt = nil
        try await update(updated)
    }

    /// Resolve the CLI binary path
    private static func resolveCliPath() -> String {
        // Check if installed via brew or in PATH
        let candidates = [
            "/usr/local/bin/scriptoria",
            "/opt/homebrew/bin/scriptoria",
            ProcessInfo.processInfo.arguments.first ?? "",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // Fallback: use swift run
        return "/usr/bin/env"
    }

    /// Compute the next run date for a schedule type
    public static func computeNextRun(for type: ScheduleType) -> Date? {
        let now = Date()
        let calendar = Calendar.current

        switch type {
        case .interval(let seconds):
            return now.addingTimeInterval(seconds)

        case .daily(let hour, let minute):
            var components = calendar.dateComponents([.year, .month, .day], from: now)
            components.hour = hour
            components.minute = minute
            components.second = 0
            guard let candidate = calendar.date(from: components) else { return nil }
            return candidate > now ? candidate : calendar.date(byAdding: .day, value: 1, to: candidate)

        case .weekly(let weekdays, let hour, let minute):
            let currentWeekday = calendar.component(.weekday, from: now)
            let sortedDays = weekdays.sorted()
            // Find next weekday
            for day in sortedDays {
                if day > currentWeekday {
                    var components = calendar.dateComponents([.year, .month, .day], from: now)
                    components.day! += (day - currentWeekday)
                    components.hour = hour
                    components.minute = minute
                    return calendar.date(from: components)
                }
            }
            // Wrap to next week
            if let firstDay = sortedDays.first {
                let daysUntil = 7 - currentWeekday + firstDay
                return calendar.date(byAdding: .day, value: daysUntil, to: now)
            }
            return nil

        case .cron:
            return now.addingTimeInterval(3600)
        }
    }
}
