import Foundation

public enum FlowExecutionMode: String, Sendable, Codable {
    case live
    case dry
}

public enum FlowWarningScope: String, Sendable, Codable {
    case run
    case state
    case system
}

public enum FlowCommandQueueAction: String, Sendable, Codable {
    case queued
    case dispatchAttempt = "dispatch_attempt"
    case accepted
    case rejectedRetry = "rejected_retry"
    case consumed
    case leftover
}

public struct FlowRunCounterSnapshot: Sendable, Codable, Equatable {
    public var name: String
    public var value: Int
    public var effectiveMax: Int

    public init(name: String, value: Int, effectiveMax: Int) {
        self.name = name
        self.value = value
        self.effectiveMax = effectiveMax
    }
}

public struct FlowRunStepError: Sendable, Codable, Equatable {
    public var code: String
    public var message: String
    public var fieldPath: String?
    public var line: Int?
    public var column: Int?

    public init(
        code: String,
        message: String,
        fieldPath: String? = nil,
        line: Int? = nil,
        column: Int? = nil
    ) {
        self.code = code
        self.message = message
        self.fieldPath = fieldPath
        self.line = line
        self.column = column
    }
}

public struct FlowRunStartedEvent: Sendable, Codable, Equatable {
    public var runID: String
    public var flowDefinitionID: String?
    public var mode: FlowExecutionMode
    public var startedAt: Date
    public var provider: String?
    public var model: String?
    public var executablePath: String?
    public var executableSource: String?

    public init(
        runID: String,
        flowDefinitionID: String?,
        mode: FlowExecutionMode,
        startedAt: Date,
        provider: String?,
        model: String?,
        executablePath: String?,
        executableSource: String?
    ) {
        self.runID = runID
        self.flowDefinitionID = flowDefinitionID
        self.mode = mode
        self.startedAt = startedAt
        self.provider = provider
        self.model = model
        self.executablePath = executablePath
        self.executableSource = executableSource
    }
}

public struct FlowStepChangedEvent: Sendable, Codable, Equatable {
    public var runID: String
    public var seq: Int
    public var phase: FlowPhase
    public var stateID: String
    public var stateType: String
    public var attempt: Int
    public var decision: String?
    public var transition: String?
    public var counter: FlowRunCounterSnapshot?
    public var duration: TimeInterval?
    public var error: FlowRunStepError?
    public var stateOutput: [String: FlowValue]?
    public var contextDelta: [String: FlowValue]?
    public var stateLast: [String: FlowValue]?

    public init(
        runID: String,
        seq: Int,
        phase: FlowPhase,
        stateID: String,
        stateType: String,
        attempt: Int,
        decision: String?,
        transition: String?,
        counter: FlowRunCounterSnapshot?,
        duration: TimeInterval?,
        error: FlowRunStepError?,
        stateOutput: [String: FlowValue]?,
        contextDelta: [String: FlowValue]?,
        stateLast: [String: FlowValue]?
    ) {
        self.runID = runID
        self.seq = seq
        self.phase = phase
        self.stateID = stateID
        self.stateType = stateType
        self.attempt = attempt
        self.decision = decision
        self.transition = transition
        self.counter = counter
        self.duration = duration
        self.error = error
        self.stateOutput = stateOutput
        self.contextDelta = contextDelta
        self.stateLast = stateLast
    }
}

public struct FlowWarningRaisedEvent: Sendable, Codable, Equatable {
    public var runID: String?
    public var code: String
    public var message: String
    public var scope: FlowWarningScope
    public var flowDefinitionID: String?
    public var stateID: String?

    public init(
        runID: String?,
        code: String,
        message: String,
        scope: FlowWarningScope,
        flowDefinitionID: String?,
        stateID: String?
    ) {
        self.runID = runID
        self.code = code
        self.message = message
        self.scope = scope
        self.flowDefinitionID = flowDefinitionID
        self.stateID = stateID
    }
}

public struct FlowCommandQueueChangedEvent: Sendable, Codable, Equatable {
    public var runID: String
    public var seq: Int
    public var action: FlowCommandQueueAction
    public var commandPreview: String
    public var queueDepth: Int
    public var stateID: String?
    public var turnID: String?
    public var reason: String?

    public init(
        runID: String,
        seq: Int,
        action: FlowCommandQueueAction,
        commandPreview: String,
        queueDepth: Int,
        stateID: String?,
        turnID: String?,
        reason: String?
    ) {
        self.runID = runID
        self.seq = seq
        self.action = action
        self.commandPreview = commandPreview
        self.queueDepth = queueDepth
        self.stateID = stateID
        self.turnID = turnID
        self.reason = reason
    }
}

public struct FlowRunCompletedEvent: Sendable, Codable, Equatable {
    public var runID: String
    public var status: FlowRunStatus
    public var endedAtStateID: String?
    public var steps: Int
    public var finishedAt: Date
    public var warningsCount: Int

    public init(
        runID: String,
        status: FlowRunStatus,
        endedAtStateID: String?,
        steps: Int,
        finishedAt: Date,
        warningsCount: Int
    ) {
        self.runID = runID
        self.status = status
        self.endedAtStateID = endedAtStateID
        self.steps = steps
        self.finishedAt = finishedAt
        self.warningsCount = warningsCount
    }
}

public enum FlowRunEvent: Sendable, Equatable {
    case runStarted(FlowRunStartedEvent)
    case stepChanged(FlowStepChangedEvent)
    case warningRaised(FlowWarningRaisedEvent)
    case commandQueueChanged(FlowCommandQueueChangedEvent)
    case runCompleted(FlowRunCompletedEvent)
}

public typealias FlowRunEventSink = @Sendable (FlowRunEvent) -> Void
