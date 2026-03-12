import Foundation

public struct FlowDefinitionRecord: Sendable, Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var displayFlowPath: String
    public var canonicalFlowPath: String
    public var workspacePath: String
    public var tags: [String]
    public var isPinned: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var lastValidatedAt: Date?
    public var lastCompiledAt: Date?
    public var lastRunAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        displayFlowPath: String,
        canonicalFlowPath: String,
        workspacePath: String,
        tags: [String] = [],
        isPinned: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastValidatedAt: Date? = nil,
        lastCompiledAt: Date? = nil,
        lastRunAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.displayFlowPath = displayFlowPath
        self.canonicalFlowPath = canonicalFlowPath
        self.workspacePath = workspacePath
        self.tags = tags
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastValidatedAt = lastValidatedAt
        self.lastCompiledAt = lastCompiledAt
        self.lastRunAt = lastRunAt
    }
}

public enum FlowRunRecordMode: String, Sendable, Codable {
    case live
    case dry
}

public enum FlowRunRecordStatus: String, Sendable, Codable {
    case running
    case success
    case failure
}

public struct FlowRunRecord: Sendable, Codable, Identifiable, Equatable {
    public var id: UUID
    public var flowDefinitionID: UUID
    public var flowPathSnapshot: String
    public var mode: FlowRunRecordMode
    public var startedAt: Date
    public var finishedAt: Date?
    public var status: FlowRunRecordStatus
    public var endedAtState: String?
    public var steps: Int
    public var errorCode: String?
    public var errorMessage: String?
    public var provider: String?
    public var model: String?
    public var executablePath: String?
    public var executableSource: String?
    public var commandsQueued: Int
    public var commandsConsumed: Int
    public var commandEventsTruncated: Bool
    public var commandEventsTruncatedCount: Int

    public init(
        id: UUID = UUID(),
        flowDefinitionID: UUID,
        flowPathSnapshot: String,
        mode: FlowRunRecordMode,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        status: FlowRunRecordStatus = .running,
        endedAtState: String? = nil,
        steps: Int = 0,
        errorCode: String? = nil,
        errorMessage: String? = nil,
        provider: String? = nil,
        model: String? = nil,
        executablePath: String? = nil,
        executableSource: String? = nil,
        commandsQueued: Int = 0,
        commandsConsumed: Int = 0,
        commandEventsTruncated: Bool = false,
        commandEventsTruncatedCount: Int = 0
    ) {
        self.id = id
        self.flowDefinitionID = flowDefinitionID
        self.flowPathSnapshot = flowPathSnapshot
        self.mode = mode
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.endedAtState = endedAtState
        self.steps = steps
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.provider = provider
        self.model = model
        self.executablePath = executablePath
        self.executableSource = executableSource
        self.commandsQueued = commandsQueued
        self.commandsConsumed = commandsConsumed
        self.commandEventsTruncated = commandEventsTruncated
        self.commandEventsTruncatedCount = commandEventsTruncatedCount
    }
}

public struct FlowStepRecord: Sendable, Codable, Identifiable, Equatable {
    public var id: Int64
    public var flowRunID: UUID
    public var seq: Int
    public var phase: String
    public var stateID: String
    public var stateType: String
    public var attempt: Int
    public var decision: String?
    public var transition: String?
    public var duration: TimeInterval?
    public var counterJSON: String?
    public var stateOutputJSON: String?
    public var contextDeltaJSON: String?
    public var stateLastJSON: String?
    public var errorCode: String?
    public var errorMessage: String?
    public var createdAt: Date

    public init(
        id: Int64,
        flowRunID: UUID,
        seq: Int,
        phase: String,
        stateID: String,
        stateType: String,
        attempt: Int,
        decision: String?,
        transition: String?,
        duration: TimeInterval?,
        counterJSON: String?,
        stateOutputJSON: String?,
        contextDeltaJSON: String?,
        stateLastJSON: String?,
        errorCode: String?,
        errorMessage: String?,
        createdAt: Date
    ) {
        self.id = id
        self.flowRunID = flowRunID
        self.seq = seq
        self.phase = phase
        self.stateID = stateID
        self.stateType = stateType
        self.attempt = attempt
        self.decision = decision
        self.transition = transition
        self.duration = duration
        self.counterJSON = counterJSON
        self.stateOutputJSON = stateOutputJSON
        self.contextDeltaJSON = contextDeltaJSON
        self.stateLastJSON = stateLastJSON
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.createdAt = createdAt
    }
}

public struct FlowWarningRecord: Sendable, Codable, Identifiable, Equatable {
    public var id: Int64
    public var scope: FlowWarningScope
    public var flowRunID: UUID?
    public var flowDefinitionID: UUID?
    public var stateID: String?
    public var code: String
    public var message: String
    public var createdAt: Date

    public init(
        id: Int64,
        scope: FlowWarningScope,
        flowRunID: UUID?,
        flowDefinitionID: UUID?,
        stateID: String?,
        code: String,
        message: String,
        createdAt: Date
    ) {
        self.id = id
        self.scope = scope
        self.flowRunID = flowRunID
        self.flowDefinitionID = flowDefinitionID
        self.stateID = stateID
        self.code = code
        self.message = message
        self.createdAt = createdAt
    }
}

public struct FlowCommandEventRecord: Sendable, Codable, Identifiable, Equatable {
    public var id: Int64
    public var flowRunID: UUID
    public var seq: Int
    public var action: FlowCommandQueueAction
    public var commandPreview: String
    public var commandHash: String
    public var queueDepth: Int
    public var stateID: String?
    public var turnID: String?
    public var reason: String?
    public var createdAt: Date

    public init(
        id: Int64,
        flowRunID: UUID,
        seq: Int,
        action: FlowCommandQueueAction,
        commandPreview: String,
        commandHash: String,
        queueDepth: Int,
        stateID: String?,
        turnID: String?,
        reason: String?,
        createdAt: Date
    ) {
        self.id = id
        self.flowRunID = flowRunID
        self.seq = seq
        self.action = action
        self.commandPreview = commandPreview
        self.commandHash = commandHash
        self.queueDepth = queueDepth
        self.stateID = stateID
        self.turnID = turnID
        self.reason = reason
        self.createdAt = createdAt
    }
}

public struct FlowCompileArtifactRecord: Sendable, Codable, Identifiable, Equatable {
    public var id: Int64
    public var flowDefinitionID: UUID
    public var sourceFlowPath: String
    public var sourceFlowHash: String
    public var outputPath: String
    public var outputHash: String
    public var fileSize: Int64
    public var createdAt: Date

    public init(
        id: Int64,
        flowDefinitionID: UUID,
        sourceFlowPath: String,
        sourceFlowHash: String,
        outputPath: String,
        outputHash: String,
        fileSize: Int64,
        createdAt: Date
    ) {
        self.id = id
        self.flowDefinitionID = flowDefinitionID
        self.sourceFlowPath = sourceFlowPath
        self.sourceFlowHash = sourceFlowHash
        self.outputPath = outputPath
        self.outputHash = outputHash
        self.fileSize = fileSize
        self.createdAt = createdAt
    }
}

public struct FlowDefinitionStatusSummary: Sendable, Equatable {
    public var definition: FlowDefinitionRecord
    public var latestRunStatus: FlowRunRecordStatus?
    public var latestErrorCode: String?
    public var latestRunAt: Date?
    public var latestSteps: Int?

    public init(
        definition: FlowDefinitionRecord,
        latestRunStatus: FlowRunRecordStatus?,
        latestErrorCode: String?,
        latestRunAt: Date?,
        latestSteps: Int?
    ) {
        self.definition = definition
        self.latestRunStatus = latestRunStatus
        self.latestErrorCode = latestErrorCode
        self.latestRunAt = latestRunAt
        self.latestSteps = latestSteps
    }
}
