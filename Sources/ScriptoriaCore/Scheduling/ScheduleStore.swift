import Foundation

/// Central store for managing schedules
public final class ScheduleStore: @unchecked Sendable {
    private let db: DatabaseManager
    private var schedules: [Schedule] = []
    private let lock = NSLock()

    public init(baseDirectory: String? = nil) {
        let dir = baseDirectory ?? Config.resolveDataDirectory()
        self.db = try! DatabaseManager(directory: dir)
    }

    public convenience init(config: Config) {
        self.init(baseDirectory: config.dataDirectory)
    }

    public static func fromConfig() -> ScheduleStore {
        ScheduleStore(config: Config.load())
    }

    // MARK: - Lifecycle

    public func load() async throws {
        let loaded = try db.fetchAllSchedules()
        lock.withLock { schedules = loaded }
    }

    public func save() async throws {
        // No-op: writes happen immediately in each mutation method
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
        try db.insertSchedule(schedule)
        lock.withLock { schedules.append(schedule) }
        return schedule
    }

    public func update(_ schedule: Schedule) async throws {
        try db.updateSchedule(schedule)
        lock.withLock {
            if let index = schedules.firstIndex(where: { $0.id == schedule.id }) {
                schedules[index] = schedule
            }
        }
    }

    public func remove(id: UUID) async throws {
        try db.deleteSchedule(id: id)
        lock.withLock { schedules.removeAll { $0.id == id } }
    }

    public func removeForScript(scriptId: UUID) async throws {
        let toRemove = lock.withLock { schedules.filter { $0.scriptId == scriptId } }
        for schedule in toRemove {
            if LaunchdHelper.isInstalled(scheduleId: schedule.id) {
                try? LaunchdHelper.uninstall(scheduleId: schedule.id)
            }
        }
        try db.deleteSchedules(scriptId: scriptId)
        lock.withLock { schedules.removeAll { $0.scriptId == scriptId } }
    }

    // MARK: - launchd integration

    public func activate(_ schedule: Schedule) async throws {
        let cliPath = ScheduleStore.resolveCliPath()
        try LaunchdHelper.install(schedule: schedule, cliPath: cliPath)
        var updated = schedule
        updated.isEnabled = true
        updated.nextRunAt = ScheduleStore.computeNextRun(for: schedule.type)
        try await update(updated)
    }

    public func deactivate(_ schedule: Schedule) async throws {
        if LaunchdHelper.isInstalled(scheduleId: schedule.id) {
            try LaunchdHelper.uninstall(scheduleId: schedule.id)
        }
        var updated = schedule
        updated.isEnabled = false
        updated.nextRunAt = nil
        try await update(updated)
    }

    private static func resolveCliPath() -> String {
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
        return "/usr/bin/env"
    }

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
            for day in sortedDays {
                if day > currentWeekday {
                    var components = calendar.dateComponents([.year, .month, .day], from: now)
                    components.day! += (day - currentWeekday)
                    components.hour = hour
                    components.minute = minute
                    return calendar.date(from: components)
                }
            }
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
