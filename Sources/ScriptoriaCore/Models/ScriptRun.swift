import Foundation

/// Record of a single script execution
public struct ScriptRun: Codable, Identifiable, Sendable {
    public var id: UUID
    public var scriptId: UUID
    public var scriptTitle: String
    public var startedAt: Date
    public var finishedAt: Date?
    public var status: RunStatus
    public var exitCode: Int32?
    public var output: String
    public var errorOutput: String
    public var pid: Int32?

    public init(
        id: UUID = UUID(),
        scriptId: UUID,
        scriptTitle: String,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        status: RunStatus = .running,
        exitCode: Int32? = nil,
        output: String = "",
        errorOutput: String = "",
        pid: Int32? = nil
    ) {
        self.id = id
        self.scriptId = scriptId
        self.scriptTitle = scriptTitle
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.exitCode = exitCode
        self.output = output
        self.errorOutput = errorOutput
        self.pid = pid
    }

    /// Duration of the run in seconds
    public var duration: TimeInterval? {
        guard let finishedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt)
    }
}
