import Foundation

/// Per-script profile for post-script agent runs
public struct ScriptAgentProfile: Codable, Identifiable, Sendable {
    public var id: Int
    public var scriptId: UUID
    public var taskName: String
    public var defaultModel: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: Int,
        scriptId: UUID,
        taskName: String,
        defaultModel: String,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.scriptId = scriptId
        self.taskName = taskName
        self.defaultModel = defaultModel
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

