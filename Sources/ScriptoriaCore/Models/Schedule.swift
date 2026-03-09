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
    /// Run on specific weekdays at a time
    case weekly(weekdays: [Int], hour: Int, minute: Int)
    /// Cron expression string
    case cron(String)
}
