import Foundation

/// Schedule configuration for a script
public struct Schedule: Codable, Identifiable, Sendable {
    public var id: UUID
    public var scriptId: UUID
    public var type: ScheduleType
    public var isEnabled: Bool
    public var createdAt: Date
    public var nextRunAt: Date?

    public init(
        id: UUID = UUID(),
        scriptId: UUID,
        type: ScheduleType,
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        nextRunAt: Date? = nil
    ) {
        self.id = id
        self.scriptId = scriptId
        self.type = type
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.nextRunAt = nextRunAt
    }
}

/// Type of schedule
public enum ScheduleType: Codable, Sendable {
    /// Run at a specific interval (in seconds)
    case interval(TimeInterval)
    /// Run at specific time daily
    case daily(hour: Int, minute: Int)
    /// Run on specific weekdays at a time (weekday: 1=Sun, 2=Mon, ..., 7=Sat)
    case weekly(weekdays: [Int], hour: Int, minute: Int)
    /// Cron expression string
    case cron(String)

    /// Human-readable description
    public var displayText: String {
        switch self {
        case .interval(let seconds):
            if seconds < 60 {
                return "Every \(Int(seconds))s"
            } else if seconds < 3600 {
                return "Every \(Int(seconds / 60))m"
            } else {
                return "Every \(Int(seconds / 3600))h"
            }
        case .daily(let hour, let minute):
            return String(format: "Daily at %02d:%02d", hour, minute)
        case .weekly(let weekdays, let hour, let minute):
            let dayNames = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            let days = weekdays.map { dayNames[min($0, 7)] }.joined(separator: ", ")
            return String(format: "%@ at %02d:%02d", days, hour, minute)
        case .cron(let expr):
            return "Cron: \(expr)"
        }
    }
}
