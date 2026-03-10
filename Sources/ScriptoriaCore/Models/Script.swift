import Foundation

/// Represents an automation script managed by Scriptoria
public struct Script: Codable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var description: String
    public var path: String
    public var skill: String
    public var agentTaskId: Int?
    public var agentTaskName: String
    public var defaultModel: String
    public var interpreter: Interpreter
    public var tags: [String]
    public var isFavorite: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var lastRunAt: Date?
    public var lastRunStatus: RunStatus?
    public var runCount: Int

    public init(
        id: UUID = UUID(),
        title: String,
        description: String = "",
        path: String,
        skill: String = "",
        agentTaskId: Int? = nil,
        agentTaskName: String = "",
        defaultModel: String = "",
        interpreter: Interpreter = .auto,
        tags: [String] = [],
        isFavorite: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastRunAt: Date? = nil,
        lastRunStatus: RunStatus? = nil,
        runCount: Int = 0
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.path = path
        self.skill = skill
        self.agentTaskId = agentTaskId
        self.agentTaskName = agentTaskName
        self.defaultModel = defaultModel
        self.interpreter = interpreter
        self.tags = tags
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastRunAt = lastRunAt
        self.lastRunStatus = lastRunStatus
        self.runCount = runCount
    }
}

/// Interpreter used to run the script
public enum Interpreter: String, Codable, Sendable, CaseIterable {
    case auto
    case bash
    case zsh
    case sh
    case node
    case python
    case python3
    case ruby
    case osascript   // AppleScript
    case binary      // Direct execution

    /// Returns the executable path for this interpreter
    public var executablePath: String? {
        switch self {
        case .auto: return nil
        case .bash: return "/bin/bash"
        case .zsh: return "/bin/zsh"
        case .sh: return "/bin/sh"
        case .node: return "/usr/local/bin/node"
        case .python: return "/usr/bin/python"
        case .python3: return "/usr/bin/python3"
        case .ruby: return "/usr/bin/ruby"
        case .osascript: return "/usr/bin/osascript"
        case .binary: return nil
        }
    }

    /// The executable name used for runtime resolution via `which`
    public var executableName: String {
        switch self {
        case .auto: return "sh"
        case .bash: return "bash"
        case .zsh: return "zsh"
        case .sh: return "sh"
        case .node: return "node"
        case .python: return "python"
        case .python3: return "python3"
        case .ruby: return "ruby"
        case .osascript: return "osascript"
        case .binary: return ""
        }
    }
}

/// Status of a script run
public enum RunStatus: String, Codable, Sendable {
    case success
    case failure
    case running
    case cancelled
}
