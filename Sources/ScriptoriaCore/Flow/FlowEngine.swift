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

    public init(
        contextOverrides: [String: String] = [:],
        maxAgentRoundsCap: Int? = nil,
        noSteer: Bool = false,
        commands: [String] = []
    ) {
        self.contextOverrides = contextOverrides
        self.maxAgentRoundsCap = maxAgentRoundsCap
        self.noSteer = noSteer
        self.commands = commands
    }
}

public enum FlowRunStatus: String, Sendable {
    case success
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

actor FlowCommandQueue {
    private var items: [String]

    init(items: [String]) {
        self.items = items
    }

    func append(_ raw: String) {
        items.append(raw)
    }

    func consume(for session: PostScriptAgentSession) async -> Bool {
        var sentInterrupt = false

        while !items.isEmpty {
            let raw = items[0]
            guard let command = AgentCommandInput.parseCLI(raw) else {
                items.removeFirst()
                continue
            }

            do {
                switch command {
                case .steer(let text):
                    try await session.steer(text)
                    items.removeFirst()
                case .interrupt:
                    try await session.interrupt()
                    items.removeFirst()
                    sentInterrupt = true
                    return sentInterrupt
                }
            } catch {
                // Command was not accepted by the current turn; keep it at queue head
                // and retry when the next agent turn is active.
                break
            }
        }

        return sentInterrupt
    }

    func remainingCount() -> Int {
        items.count
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
        logSink: ((String) -> Void)? = nil
    ) async throws -> FlowRunResult {
        let runID = UUID().uuidString.lowercased()
        let stateMap = ir.stateMap()

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

        let commandQueue = FlowCommandQueue(items: options.commands)
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
                throw FlowErrors.runtime(code: "flow.steps.exceeded", "max_total_steps exceeded")
            }

            guard let state = stateMap[currentStateID] else {
                throw FlowErrors.runtime(code: "flow.validate.schema_error", "State not found during runtime: \(currentStateID)")
            }
            executedStates.insert(currentStateID)

            runtime.attempts[currentStateID, default: 0] += 1
            let attempt = runtime.attempts[currentStateID] ?? 1
            let started = Date()

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
                        warnings.append(contentsOf: fixtureWarningsOrError)
                    }

                    let remainingCommands = await commandQueue.remainingCount()
                    if remainingCommands > 0 {
                        warnings.append(
                            FlowWarning(
                                code: "flow.cli.command_unused",
                                message: "Unused --command entries: \(remainingCommands)"
                            )
                        )
                    }

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
        logSink: ((String) -> Void)?
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
        logSink: ((String) -> Void)?
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
                    message: "Dry-run fixture has unused entries for non-executed state \(stateID)"
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
        logSink: ((String) -> Void)?
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
}
