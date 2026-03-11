import Foundation

struct FlowAgentStepResult {
    var nextStateID: String
    var stateOutput: [String: FlowValue]
}

struct AgentStepRunner {
    func execute(
        state: FlowIRState,
        ir: FlowIR,
        mode: FlowRunMode,
        dryFixture: inout FlowDryRunFixture?,
        context: inout [String: FlowValue],
        counters: [String: Int],
        stateLast: [String: FlowValue],
        prev: FlowValue?,
        commandQueue: FlowCommandQueue,
        logSink: (@Sendable (String) -> Void)?
    ) async throws -> FlowAgentStepResult {
        guard let agent = state.agent,
              let next = state.next else {
            throw FlowErrors.runtime(code: "flow.validate.schema_error", "agent payload missing", stateID: state.id)
        }

        var stateOutput: [String: FlowValue] = [:]
        switch mode {
        case .live:
            let flowDirectory = URL(fileURLWithPath: ir.sourcePath).deletingLastPathComponent().path
            let prompt: String
            if let promptText = agent.prompt, !promptText.isEmpty {
                prompt = "Task: \(agent.task)\n\n\(promptText)"
            } else {
                prompt = "Task: \(agent.task)"
            }

            let session = try await PostScriptAgentRunner.launch(
                options: PostScriptAgentLaunchOptions(
                    workingDirectory: flowDirectory,
                    model: AgentRuntimeCatalog.normalizeModel(agent.model),
                    userPrompt: prompt,
                    developerInstructions: "You are running inside a Scriptoria flow state."
                )
            )

            let interruptMarker = FlowInterruptMarker()
            let immediateInterrupt = await commandQueue.consume(for: session, stateID: state.id)
            if immediateInterrupt {
                await interruptMarker.markInterrupted()
            }
            let commandRelayTask = Task.detached(priority: .utility) {
                while !Task.isCancelled {
                    let sentInterrupt = await commandQueue.consume(for: session, stateID: state.id)
                    if sentInterrupt {
                        await interruptMarker.markInterrupted()
                        return
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            let completion = try await FlowStepRunnerSupport.waitForAgentCompletion(
                session: session,
                timeoutSec: agent.timeoutSec,
                graceSec: 10,
                stateID: state.id
            )
            if let logSink, !completion.output.isEmpty {
                logSink(completion.output)
            }
            commandRelayTask.cancel()

            let interruptedByUser = await interruptMarker.isInterrupted()
            if interruptedByUser {
                throw FlowErrors.runtime(code: "flow.agent.interrupted", "Agent interrupted by command", stateID: state.id)
            }

            switch completion.status {
            case .completed:
                break
            case .interrupted:
                throw FlowErrors.runtime(code: "flow.agent.failed", "Agent was interrupted", stateID: state.id)
            case .failed:
                throw FlowErrors.runtime(code: "flow.agent.failed", "Agent failed", stateID: state.id)
            case .running:
                throw FlowErrors.runtime(code: "flow.agent.failed", "Agent still running unexpectedly", stateID: state.id)
            }

            stateOutput["status"] = .string(completion.status.rawValue)
            stateOutput["output"] = .string(completion.output)

            if let export = state.export {
                guard let final = try FlowStepRunnerSupport.parseLastLineJSONObject(text: completion.output) else {
                    throw FlowErrors.runtime(
                        code: "flow.agent.output_parse_error",
                        "agent export requires final JSON line",
                        stateID: state.id
                    )
                }
                stateOutput["final"] = .object(final)
                try FlowStepRunnerSupport.applyExport(
                    export,
                    context: &context,
                    counters: counters,
                    stateLast: stateLast,
                    prev: prev,
                    current: .object(["final": .object(final)]),
                    missingCode: "flow.agent.export_field_missing",
                    stateID: state.id
                )
            }

        case .dryRun:
            guard var fixture = dryFixture else {
                throw FlowErrors.runtimeDryRun(code: "flow.validate.schema_error", "dry-run fixture missing")
            }
            guard let item = fixture.consume(stateID: state.id) else {
                throw FlowErrors.runtimeDryRun(
                    code: "flow.dryrun.fixture_missing_state_data",
                    "Dry-run fixture missing data for state \(state.id)",
                    stateID: state.id
                )
            }
            dryFixture = fixture

            guard case .object(let object) = item else {
                throw FlowErrors.runtimeDryRun(code: "flow.validate.schema_error", "agent fixture entry must be object", stateID: state.id)
            }
            stateOutput = object

            if let status = object["status"]?.stringValue {
                if status == "failed" {
                    throw FlowErrors.runtime(code: "flow.agent.failed", "agent fixture indicated failure", stateID: state.id)
                }
                if status == "interrupted" {
                    throw FlowErrors.runtime(code: "flow.agent.interrupted", "agent fixture indicated interrupted", stateID: state.id)
                }
            }

            if let export = state.export {
                guard case .object(let final)? = object["final"] else {
                    throw FlowErrors.runtime(
                        code: "flow.agent.output_parse_error",
                        "agent export requires final JSON object",
                        stateID: state.id
                    )
                }
                try FlowStepRunnerSupport.applyExport(
                    export,
                    context: &context,
                    counters: counters,
                    stateLast: stateLast,
                    prev: prev,
                    current: .object(["final": .object(final)]),
                    missingCode: "flow.agent.export_field_missing",
                    stateID: state.id
                )
            }
        }

        return FlowAgentStepResult(nextStateID: next, stateOutput: stateOutput)
    }
}
