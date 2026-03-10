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
    public var agentTriggerMode: AgentTriggerMode
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
        defaultModel: String = AgentRuntimeCatalog.defaultModel,
        agentTriggerMode: AgentTriggerMode = .always,
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
        self.agentTriggerMode = agentTriggerMode
        self.interpreter = interpreter
        self.tags = tags
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastRunAt = lastRunAt
        self.lastRunStatus = lastRunStatus
        self.runCount = runCount
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case description
        case path
        case skill
        case agentTaskId
        case agentTaskName
        case defaultModel
        case agentTriggerMode
        case interpreter
        case tags
        case isFavorite
        case createdAt
        case updatedAt
        case lastRunAt
        case lastRunStatus
        case runCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.title = try container.decode(String.self, forKey: .title)
        self.description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.path = try container.decode(String.self, forKey: .path)
        self.skill = try container.decodeIfPresent(String.self, forKey: .skill) ?? ""
        self.agentTaskId = try container.decodeIfPresent(Int.self, forKey: .agentTaskId)
        self.agentTaskName = try container.decodeIfPresent(String.self, forKey: .agentTaskName) ?? ""
        let decodedModel = try container.decodeIfPresent(String.self, forKey: .defaultModel)
        self.defaultModel = AgentRuntimeCatalog.normalizeModel(decodedModel)
        self.agentTriggerMode = try container.decodeIfPresent(AgentTriggerMode.self, forKey: .agentTriggerMode) ?? .always
        let interpreterRaw = try container.decodeIfPresent(String.self, forKey: .interpreter) ?? Interpreter.auto.rawValue
        self.interpreter = Interpreter(rawValue: interpreterRaw) ?? .auto
        self.tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        self.lastRunAt = try container.decodeIfPresent(Date.self, forKey: .lastRunAt)
        self.lastRunStatus = try container.decodeIfPresent(RunStatus.self, forKey: .lastRunStatus)
        self.runCount = try container.decodeIfPresent(Int.self, forKey: .runCount) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(description, forKey: .description)
        try container.encode(path, forKey: .path)
        try container.encode(skill, forKey: .skill)
        try container.encodeIfPresent(agentTaskId, forKey: .agentTaskId)
        try container.encode(agentTaskName, forKey: .agentTaskName)
        try container.encode(defaultModel, forKey: .defaultModel)
        try container.encode(agentTriggerMode, forKey: .agentTriggerMode)
        try container.encode(interpreter.rawValue, forKey: .interpreter)
        try container.encode(tags, forKey: .tags)
        try container.encode(isFavorite, forKey: .isFavorite)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(lastRunAt, forKey: .lastRunAt)
        try container.encodeIfPresent(lastRunStatus, forKey: .lastRunStatus)
        try container.encode(runCount, forKey: .runCount)
    }
}

public enum AgentTriggerMode: String, Codable, Sendable, CaseIterable {
    case always
    case preScriptTrue

    public var displayName: String {
        switch self {
        case .always:
            return "Always (on script success)"
        case .preScriptTrue:
            return "Only when pre-script is true"
        }
    }

    public var helperText: String {
        switch self {
        case .always:
            return "Run post-script agent stage whenever the script exits successfully."
        case .preScriptTrue:
            return "Run agent only when script STDOUT last non-empty line is true."
        }
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
