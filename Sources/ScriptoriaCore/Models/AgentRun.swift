import Foundation

public enum AgentRunStatus: String, Codable, Sendable {
    case running
    case completed
    case interrupted
    case failed
}

/// Record of a post-script agent execution
public struct AgentRun: Codable, Identifiable, Sendable {
    public var id: UUID
    public var scriptId: UUID
    public var scriptRunId: UUID?
    public var taskId: Int?
    public var taskName: String
    public var model: String
    public var threadId: String
    public var turnId: String
    public var startedAt: Date
    public var finishedAt: Date?
    public var status: AgentRunStatus
    public var finalMessage: String
    public var output: String
    public var taskMemoryPath: String?

    public init(
        id: UUID = UUID(),
        scriptId: UUID,
        scriptRunId: UUID? = nil,
        taskId: Int? = nil,
        taskName: String,
        model: String,
        threadId: String,
        turnId: String,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        status: AgentRunStatus = .running,
        finalMessage: String = "",
        output: String = "",
        taskMemoryPath: String? = nil
    ) {
        self.id = id
        self.scriptId = scriptId
        self.scriptRunId = scriptRunId
        self.taskId = taskId
        self.taskName = taskName
        self.model = model
        self.threadId = threadId
        self.turnId = turnId
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.finalMessage = finalMessage
        self.output = output
        self.taskMemoryPath = taskMemoryPath
    }

    public var duration: TimeInterval? {
        guard let finishedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt)
    }
}

