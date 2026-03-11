import Foundation

public enum FlowRunMode: Sendable {
    case live
    case dryRun(FlowDryRunFixture)
}

public struct FlowRunOptions: Sendable {
    public var contextOverrides: [String: String]
    public var maxAgentRoundsCap: Int?
    public var noSteer: Bool
    public var commands: [String]
    public var runID: String?
    public var flowDefinitionID: String?

    public init(
        contextOverrides: [String: String] = [:],
        maxAgentRoundsCap: Int? = nil,
        noSteer: Bool = false,
        commands: [String] = [],
        runID: String? = nil,
        flowDefinitionID: String? = nil
    ) {
        self.contextOverrides = contextOverrides
        self.maxAgentRoundsCap = maxAgentRoundsCap
        self.noSteer = noSteer
        self.commands = commands
        self.runID = runID
        self.flowDefinitionID = flowDefinitionID
    }
}

public enum FlowRunStatus: String, Sendable, Codable {
    case success
    case failure
}

public struct FlowRunResult: Sendable {
    public var status: FlowRunStatus
    public var runID: String
    public var endedAtStateID: String
    public var context: [String: FlowValue]
    public var counters: [String: Int]
    public var steps: Int
    public var warnings: [FlowWarning]
}

private struct FlowRuntimeState {
    var context: [String: FlowValue]
    var counters: [String: Int]
    var stateLast: [String: FlowValue]
    var prev: FlowValue?
    var attempts: [String: Int]
    var waitCycles: Int
    var totalSteps: Int
}

private struct FlowStepOutcome {
    var nextStateID: String?
    var decision: FlowGateDecision?
    var counter: (name: String, value: Int, effectiveMax: Int)?
    var stateOutput: FlowValue?
}

private struct FlowRuntimeMetadata {
    var provider: String?
    var model: String?
    var executablePath: String?
    var executableSource: String?
}

actor FlowCommandQueue {
    private var items: [String]
    private let runID: String
    private let eventSink: (@Sendable (FlowCommandQueueChangedEvent) -> Void)?
    private var nextEventSeq: Int = 1

    init(
        items: [String],
        runID: String,
        eventSink: (@Sendable (FlowCommandQueueChangedEvent) -> Void)?
    ) {
        self.items = items
        self.runID = runID
        self.eventSink = eventSink
        if let eventSink {
            for (index, raw) in items.enumerated() {
                let event = FlowCommandQueueChangedEvent(
                    runID: runID,
                    seq: nextEventSeq,
                    action: .queued,
                    commandPreview: Self.commandPreview(from: raw),
                    queueDepth: index + 1,
                    stateID: nil,
                    turnID: nil,
                    reason: nil
                )
                nextEventSeq += 1
                eventSink(event)
            }
        }
    }

    func append(_ raw: String, stateID: String? = nil) {
        items.append(raw)
        emit(
            action: .queued,
            commandPreview: Self.commandPreview(from: raw),
            queueDepth: items.count,
            stateID: stateID,
            turnID: nil,
            reason: nil
        )
    }

    func consume(for session: PostScriptAgentSession, stateID: String?) async -> Bool {
        var sentInterrupt = false

        while !items.isEmpty {
            let raw = items[0]
            let preview = Self.commandPreview(from: raw)
            let turnID = await session.turnId.nilIfEmpty
            emit(
                action: .dispatchAttempt,
                commandPreview: preview,
                queueDepth: items.count,
                stateID: stateID,
                turnID: turnID,
                reason: nil
            )

            guard let command = AgentCommandInput.parseCLI(raw) else {
                items.removeFirst()
                emit(
                    action: .consumed,
                    commandPreview: preview,
                    queueDepth: items.count,
                    stateID: stateID,
                    turnID: turnID,
                    reason: "invalid_command"
                )
                continue
            }

            do {
                switch command {
                case .steer(let text):
                    try await session.steer(text)
                    emit(
                        action: .accepted,
                        commandPreview: preview,
                        queueDepth: items.count,
                        stateID: stateID,
                        turnID: turnID,
                        reason: nil
                    )
                    items.removeFirst()
                    emit(
                        action: .consumed,
                        commandPreview: preview,
                        queueDepth: items.count,
                        stateID: stateID,
                        turnID: turnID,
                        reason: nil
                    )
                case .interrupt:
                    try await session.interrupt()
                    emit(
                        action: .accepted,
                        commandPreview: preview,
                        queueDepth: items.count,
                        stateID: stateID,
                        turnID: turnID,
                        reason: nil
                    )
                    items.removeFirst()
                    emit(
                        action: .consumed,
                        commandPreview: preview,
                        queueDepth: items.count,
                        stateID: stateID,
                        turnID: turnID,
                        reason: nil
                    )
                    sentInterrupt = true
                    return sentInterrupt
                }
            } catch {
                // Command was not accepted by the current turn; keep it at queue head
                // and retry when the next agent turn is active.
                emit(
                    action: .rejectedRetry,
                    commandPreview: preview,
                    queueDepth: items.count,
                    stateID: stateID,
                    turnID: turnID,
                    reason: Self.sanitize(error.localizedDescription)
                )
                break
            }
        }

        return sentInterrupt
    }

    func remainingCount() -> Int {
        items.count
    }

    func remainingCommands() -> [String] {
        items
    }

    private func emit(
        action: FlowCommandQueueAction,
        commandPreview: String,
        queueDepth: Int,
        stateID: String?,
        turnID: String?,
        reason: String?
    ) {
        guard let eventSink else { return }
        let event = FlowCommandQueueChangedEvent(
            runID: runID,
            seq: nextEventSeq,
            action: action,
            commandPreview: commandPreview,
            queueDepth: queueDepth,
            stateID: stateID,
            turnID: turnID,
            reason: reason
        )
        nextEventSeq += 1
        eventSink(event)
    }

    private static func commandPreview(from raw: String) -> String {
        let sanitized = sanitize(raw)
        if sanitized.count <= 120 {
            return sanitized
        }
        return String(sanitized.prefix(120))
    }

    private static func sanitize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
    }
}

public final class FlowEngine: Sendable {
    private let scriptRunner: ScriptRunner

    public init(scriptRunner: ScriptRunner = ScriptRunner()) {
        self.scriptRunner = scriptRunner
    }

    public func run(
        ir: FlowIR,
        mode: FlowRunMode,
        options: FlowRunOptions = .init(),
        commandInput: AsyncStream<String>? = nil,
        logSink: (@Sendable (String) -> Void)? = nil,
        eventSink: FlowRunEventSink? = nil
    ) async throws -> FlowRunResult {
        let runID = options.runID?.lowercased() ?? UUID().uuidString.lowercased()
        let startedAt = Date()
        let stateMap = ir.stateMap()
        let metadata = inferRuntimeMetadata(ir: ir)
        let executionMode: FlowExecutionMode
        switch mode {
        case .live:
            executionMode = .live
        case .dryRun:
            executionMode = .dry
        }

        eventSink?(
            .runStarted(
                FlowRunStartedEvent(
                    runID: runID,
                    flowDefinitionID: options.flowDefinitionID,
                    mode: executionMode,
                    startedAt: startedAt,
                    provider: metadata.provider,
                    model: metadata.model,
                    executablePath: metadata.executablePath,
                    executableSource: metadata.executableSource
                )
            )
        )

        var runtime = FlowRuntimeState(
            context: ir.context,
            counters: [:],
            stateLast: [:],
            prev: nil,
            attempts: [:],
            waitCycles: 0,
            totalSteps: 0
        )
        for (key, value) in options.contextOverrides {
            runtime.context[key] = .string(value)
        }

        var warnings: [FlowWarning] = []
        var dryFixture: FlowDryRunFixture?
        var executedStates: Set<String> = []
        var stepSeq = 0

        switch mode {
        case .live:
            break
        case .dryRun(let fixture):
            for stateID in fixture.states.keys where stateMap[stateID] == nil {
                throw FlowErrors.runtimeDryRun(
                    code: "flow.dryrun.fixture_unknown_state",
                    "Dry-run fixture contains unknown state: \(stateID)",
                    stateID: stateID
                )
            }
            dryFixture = fixture
        }

        let commandQueue = FlowCommandQueue(
            items: options.commands,
            runID: runID,
            eventSink: { event in
                eventSink?(.commandQueueChanged(event))
            }
        )
        let commandInputTask: Task<Void, Never>?
        if let commandInput {
            commandInputTask = Task.detached(priority: .utility) {
                for await raw in commandInput {
                    await commandQueue.append(raw)
                }
            }
        } else {
            commandInputTask = nil
        }
        defer {
            commandInputTask?.cancel()
        }

        var currentStateID = ir.start

        while true {
            runtime.totalSteps += 1
            if runtime.totalSteps > ir.defaults.maxTotalSteps {
                let failure = FlowErrors.runtime(code: "flow.steps.exceeded", "max_total_steps exceeded")
                eventSink?(
                    .runCompleted(
                        FlowRunCompletedEvent(
                            runID: runID,
                            status: .failure,
                            endedAtStateID: currentStateID,
                            steps: runtime.totalSteps,
                            finishedAt: Date(),
                            warningsCount: warnings.count
                        )
                    )
                )
                throw failure
            }

            guard let state = stateMap[currentStateID] else {
                let failure = FlowErrors.runtime(
                    code: "flow.validate.schema_error",
                    "State not found during runtime: \(currentStateID)"
                )
                eventSink?(
                    .runCompleted(
                        FlowRunCompletedEvent(
                            runID: runID,
                            status: .failure,
                            endedAtStateID: currentStateID,
                            steps: runtime.totalSteps,
                            finishedAt: Date(),
                            warningsCount: warnings.count
                        )
                    )
                )
                throw failure
            }
            executedStates.insert(currentStateID)

            runtime.attempts[currentStateID, default: 0] += 1
            let attempt = runtime.attempts[currentStateID] ?? 1
            let started = Date()
            let contextBefore = runtime.context

            do {
                let outcome = try await executeStep(
                    state,
                    ir: ir,
                    mode: mode,
                    dryFixture: &dryFixture,
                    runtime: &runtime,
                    commandQueue: commandQueue,
                    options: options,
                    logSink: logSink
                )
                let duration = Date().timeIntervalSince(started)

                if let output = outcome.stateOutput {
                    runtime.stateLast[currentStateID] = output
                    runtime.prev = output
                }

                emitLog(
                    phase: .runtime,
                    runID: runID,
                    stateID: currentStateID,
                    stateType: state.kind.rawValue,
                    attempt: attempt,
                    counter: outcome.counter,
                    decision: outcome.decision?.rawValue,
                    transition: outcome.nextStateID,
                    duration: duration,
                    logSink: logSink
                )

                stepSeq += 1
                eventSink?(
                    .stepChanged(
                        FlowStepChangedEvent(
                            runID: runID,
                            seq: stepSeq,
                            phase: .runtime,
                            stateID: currentStateID,
                            stateType: state.kind.rawValue,
                            attempt: attempt,
                            decision: outcome.decision?.rawValue,
                            transition: outcome.nextStateID,
                            counter: outcome.counter.map {
                                FlowRunCounterSnapshot(name: $0.name, value: $0.value, effectiveMax: $0.effectiveMax)
                            },
                            duration: duration,
                            error: nil,
                            stateOutput: objectValue(from: outcome.stateOutput),
                            contextDelta: contextDelta(before: contextBefore, after: runtime.context),
                            stateLast: objectValue(from: runtime.stateLast[currentStateID])
                        )
                    )
                )

                if state.kind == .end {
                    guard let end = state.end else {
                        throw FlowErrors.runtime(code: "flow.validate.schema_error", "end payload missing", stateID: state.id)
                    }
                    if end.status == .failure {
                        throw FlowErrors.runtime(code: "flow.business_failed", end.message ?? "Business failure reached", stateID: state.id)
                    }

                    if case .dryRun = mode,
                       let dryFixture {
                        let fixtureWarningsOrError = try finalizeDryRunFixture(
                            fixture: dryFixture,
                            executedStates: executedStates
                        )
                        for warning in fixtureWarningsOrError {
                            warnings.append(warning)
                            eventSink?(
                                .warningRaised(
                                    FlowWarningRaisedEvent(
                                        runID: runID,
                                        code: warning.code,
                                        message: warning.message,
                                        scope: warning.scope,
                                        flowDefinitionID: options.flowDefinitionID,
                                        stateID: warning.stateID
                                    )
                                )
                            )
                        }
                    }

                    let remainingCommands = await commandQueue.remainingCount()
                    if remainingCommands > 0 {
                        let leftoverPreview = await commandQueue.remainingCommands().first.map {
                            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        } ?? "leftover"
                        eventSink?(
                            .commandQueueChanged(
                                FlowCommandQueueChangedEvent(
                                    runID: runID,
                                    seq: Int.max,
                                    action: .leftover,
                                    commandPreview: leftoverPreview,
                                    queueDepth: remainingCommands,
                                    stateID: currentStateID,
                                    turnID: nil,
                                    reason: "run_completed_with_unconsumed_commands"
                                )
                            )
                        )

                        let warning = FlowWarning(
                            code: "flow.cli.command_unused",
                            message: "Unused --command entries: \(remainingCommands)",
                            scope: .run,
                            stateID: nil
                        )
                        warnings.append(warning)
                        eventSink?(
                            .warningRaised(
                                FlowWarningRaisedEvent(
                                    runID: runID,
                                    code: warning.code,
                                    message: warning.message,
                                    scope: warning.scope,
                                    flowDefinitionID: options.flowDefinitionID,
                                    stateID: warning.stateID
                                )
                            )
                        )
                    }

                    let completedAt = Date()
                    eventSink?(
                        .runCompleted(
                            FlowRunCompletedEvent(
                                runID: runID,
                                status: .success,
                                endedAtStateID: state.id,
                                steps: runtime.totalSteps,
                                finishedAt: completedAt,
                                warningsCount: warnings.count
                            )
                        )
                    )

                    return FlowRunResult(
                        status: .success,
                        runID: runID,
                        endedAtStateID: state.id,
                        context: runtime.context,
                        counters: runtime.counters,
                        steps: runtime.totalSteps,
                        warnings: warnings
                    )
                }

                guard let next = outcome.nextStateID else {
                    throw FlowErrors.runtime(code: "flow.validate.schema_error", "Missing transition from state \(state.id)")
                }
                currentStateID = next
            } catch let error as FlowError {
                let duration = Date().timeIntervalSince(started)
                emitLog(
                    phase: error.phase,
                    runID: runID,
                    stateID: currentStateID,
                    stateType: state.kind.rawValue,
                    attempt: attempt,
                    counter: nil,
                    decision: nil,
                    transition: nil,
                    duration: duration,
                    errorCode: error.code,
                    errorMessage: error.message,
                    logSink: logSink
                )

                stepSeq += 1
                eventSink?(
                    .stepChanged(
                        FlowStepChangedEvent(
                            runID: runID,
                            seq: stepSeq,
                            phase: error.phase,
                            stateID: currentStateID,
                            stateType: state.kind.rawValue,
                            attempt: attempt,
                            decision: nil,
                            transition: nil,
                            counter: nil,
                            duration: duration,
                            error: FlowRunStepError(
                                code: error.code,
                                message: error.message,
                                fieldPath: error.fieldPath,
                                line: error.line,
                                column: error.column
                            ),
                            stateOutput: nil,
                            contextDelta: contextDelta(before: contextBefore, after: runtime.context),
                            stateLast: objectValue(from: runtime.stateLast[currentStateID])
                        )
                    )
                )

                eventSink?(
                    .runCompleted(
                        FlowRunCompletedEvent(
                            runID: runID,
                            status: .failure,
                            endedAtStateID: currentStateID,
                            steps: runtime.totalSteps,
                            finishedAt: Date(),
                            warningsCount: warnings.count
                        )
                    )
                )
                throw error
            }
        }
    }

    private func executeStep(
        _ state: FlowIRState,
        ir: FlowIR,
        mode: FlowRunMode,
        dryFixture: inout FlowDryRunFixture?,
        runtime: inout FlowRuntimeState,
        commandQueue: FlowCommandQueue,
        options: FlowRunOptions,
        logSink: (@Sendable (String) -> Void)?
    ) async throws -> FlowStepOutcome {
        switch state.kind {
        case .gate:
            return try await executeGate(
                state,
                ir: ir,
                mode: mode,
                dryFixture: &dryFixture,
                runtime: &runtime
            )

        case .script:
            return try await executeScript(
                state,
                ir: ir,
                mode: mode,
                dryFixture: &dryFixture,
                runtime: &runtime
            )

        case .agent:
            return try await executeAgent(
                state,
                ir: ir,
                mode: mode,
                dryFixture: &dryFixture,
                runtime: &runtime,
                commandQueue: commandQueue,
                options: options,
                logSink: logSink
            )

        case .wait:
            return try await executeWait(state, ir: ir, mode: mode, runtime: &runtime)

        case .end:
            return FlowStepOutcome(nextStateID: nil, decision: nil, counter: nil, stateOutput: .object([:]))
        }
    }

    private func executeGate(
        _ state: FlowIRState,
        ir: FlowIR,
        mode: FlowRunMode,
        dryFixture: inout FlowDryRunFixture?,
        runtime: inout FlowRuntimeState
    ) async throws -> FlowStepOutcome {
        let result = try await GateStepRunner(scriptRunner: scriptRunner).execute(
            state: state,
            ir: ir,
            mode: mode,
            dryFixture: &dryFixture,
            context: runtime.context,
            counters: runtime.counters,
            stateLast: runtime.stateLast,
            prev: runtime.prev
        )
        return FlowStepOutcome(
            nextStateID: result.nextStateID,
            decision: result.decision,
            counter: nil,
            stateOutput: .object(result.stateOutput)
        )
    }

    private func executeScript(
        _ state: FlowIRState,
        ir: FlowIR,
        mode: FlowRunMode,
        dryFixture: inout FlowDryRunFixture?,
        runtime: inout FlowRuntimeState
    ) async throws -> FlowStepOutcome {
        let result = try await ScriptStepRunner(scriptRunner: scriptRunner).execute(
            state: state,
            ir: ir,
            mode: mode,
            dryFixture: &dryFixture,
            context: &runtime.context,
            counters: runtime.counters,
            stateLast: runtime.stateLast,
            prev: runtime.prev
        )
        return FlowStepOutcome(
            nextStateID: result.nextStateID,
            decision: nil,
            counter: nil,
            stateOutput: .object(result.stateOutput)
        )
    }

    private func executeAgent(
        _ state: FlowIRState,
        ir: FlowIR,
        mode: FlowRunMode,
        dryFixture: inout FlowDryRunFixture?,
        runtime: inout FlowRuntimeState,
        commandQueue: FlowCommandQueue,
        options: FlowRunOptions,
        logSink: (@Sendable (String) -> Void)?
    ) async throws -> FlowStepOutcome {
        guard let agent = state.agent,
              state.next != nil else {
            throw FlowErrors.runtime(code: "flow.validate.schema_error", "agent payload missing", stateID: state.id)
        }

        let current = runtime.counters[agent.counter, default: 0]
        let nextCounterValue = current + 1
        let effectiveMax: Int
        if let cliCap = options.maxAgentRoundsCap {
            effectiveMax = min(agent.maxRounds, ir.defaults.maxAgentRounds, cliCap)
        } else {
            effectiveMax = min(agent.maxRounds, ir.defaults.maxAgentRounds)
        }
        if nextCounterValue > effectiveMax {
            throw FlowErrors.runtime(
                code: "flow.agent.rounds_exceeded",
                "agent rounds exceeded for counter \(agent.counter)",
                stateID: state.id
            )
        }
        runtime.counters[agent.counter] = nextCounterValue

        let result = try await AgentStepRunner().execute(
            state: state,
            ir: ir,
            mode: mode,
            dryFixture: &dryFixture,
            context: &runtime.context,
            counters: runtime.counters,
            stateLast: runtime.stateLast,
            prev: runtime.prev,
            commandQueue: commandQueue,
            logSink: logSink
        )
        return FlowStepOutcome(
            nextStateID: result.nextStateID,
            decision: nil,
            counter: (name: agent.counter, value: nextCounterValue, effectiveMax: effectiveMax),
            stateOutput: .object(result.stateOutput)
        )
    }

    private func executeWait(
        _ state: FlowIRState,
        ir: FlowIR,
        mode: FlowRunMode,
        runtime: inout FlowRuntimeState
    ) async throws -> FlowStepOutcome {
        guard state.wait != nil,
              state.next != nil else {
            throw FlowErrors.runtime(code: "flow.validate.schema_error", "wait payload missing", stateID: state.id)
        }

        runtime.waitCycles += 1
        if runtime.waitCycles > ir.defaults.maxWaitCycles {
            throw FlowErrors.runtime(code: "flow.wait.cycles_exceeded", "max_wait_cycles exceeded", stateID: state.id)
        }

        let result = try await WaitStepRunner().execute(
            state: state,
            ir: ir,
            mode: mode,
            context: runtime.context,
            counters: runtime.counters,
            stateLast: runtime.stateLast,
            prev: runtime.prev
        )
        return FlowStepOutcome(
            nextStateID: result.nextStateID,
            decision: nil,
            counter: nil,
            stateOutput: .object(result.stateOutput)
        )
    }

    private func finalizeDryRunFixture(
        fixture: FlowDryRunFixture,
        executedStates: Set<String>
    ) throws -> [FlowWarning] {
        var warnings: [FlowWarning] = []
        for (stateID, entries) in fixture.states {
            guard !entries.isEmpty else { continue }
            if executedStates.contains(stateID) {
                throw FlowErrors.runtimeDryRun(
                    code: "flow.dryrun.fixture_unconsumed_items",
                    "Dry-run fixture has unconsumed entries for executed state \(stateID)",
                    stateID: stateID
                )
            }
            warnings.append(
                FlowWarning(
                    code: "flow.dryrun.fixture_unused_state_data",
                    message: "Dry-run fixture has unused entries for non-executed state \(stateID)",
                    scope: .state,
                    stateID: stateID
                )
            )
        }
        return warnings
    }

    private func emitLog(
        phase: FlowPhase,
        runID: String,
        stateID: String,
        stateType: String,
        attempt: Int,
        counter: (name: String, value: Int, effectiveMax: Int)?,
        decision: String?,
        transition: String?,
        duration: TimeInterval,
        errorCode: String? = nil,
        errorMessage: String? = nil,
        logSink: (@Sendable (String) -> Void)?
    ) {
        guard let logSink else { return }

        let counterText: String
        if let counter {
            counterText = "{\"name\":\"\(counter.name)\",\"value\":\(counter.value),\"effective_max\":\(counter.effectiveMax)}"
        } else {
            counterText = "null"
        }

        var fields: [String] = [
            "phase=\(phase.rawValue)",
            "run_id=\(runID)",
            "state_id=\(stateID)",
            "state_type=\(stateType)",
            "attempt=\(attempt)",
            "counter=\(counterText)",
            "decision=\(decision ?? "null")",
            "transition=\(transition ?? "null")",
            String(format: "duration=%.3f", duration)
        ]

        if let errorCode {
            fields.append("error_code=\(errorCode)")
        }
        if let errorMessage {
            fields.append("error_message=\(sanitizeLogValue(errorMessage))")
        }

        logSink(fields.joined(separator: " "))
    }

    private func sanitizeLogValue(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ")
    }

    private func objectValue(from value: FlowValue?) -> [String: FlowValue]? {
        guard let value else { return nil }
        guard case .object(let object) = value else { return nil }
        return object
    }

    private func contextDelta(
        before: [String: FlowValue],
        after: [String: FlowValue]
    ) -> [String: FlowValue]? {
        let keys = Set(before.keys).union(after.keys)
        var delta: [String: FlowValue] = [:]
        for key in keys {
            let lhs = before[key]
            let rhs = after[key]
            if lhs != rhs {
                delta[key] = rhs ?? .null
            }
        }
        return delta.isEmpty ? nil : delta
    }

    private func inferRuntimeMetadata(ir: FlowIR) -> FlowRuntimeMetadata {
        let configuredExec = ProcessInfo.processInfo.environment["SCRIPTORIA_CODEX_EXECUTABLE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let executablePath = (configuredExec?.isEmpty == false) ? configuredExec : "codex"
        let executableSource = (configuredExec?.isEmpty == false) ? "SCRIPTORIA_CODEX_EXECUTABLE" : "default"

        let provider: String?
        if let executablePath {
            let token = URL(fileURLWithPath: executablePath).lastPathComponent.lowercased()
            if token.contains("claude") {
                provider = "claude"
            } else if token.contains("kimi") {
                provider = "kimi"
            } else {
                provider = "codex"
            }
        } else {
            provider = nil
        }

        let model = ir.states.first(where: { $0.kind == .agent })?.agent?.model.map(AgentRuntimeCatalog.normalizeModel)

        return FlowRuntimeMetadata(
            provider: provider,
            model: model,
            executablePath: executablePath,
            executableSource: executableSource
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
