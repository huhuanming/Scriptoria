import Foundation

struct FlowGateStepResult {
    var nextStateID: String
    var decision: FlowGateDecision
    var stateOutput: [String: FlowValue]
}

struct GateStepRunner {
    let scriptRunner: ScriptRunner

    func execute(
        state: FlowIRState,
        ir: FlowIR,
        mode: FlowRunMode,
        dryFixture: inout FlowDryRunFixture?,
        context: [String: FlowValue],
        counters: [String: Int],
        stateLast: [String: FlowValue],
        prev: FlowValue?
    ) async throws -> FlowGateStepResult {
        guard let transitions = state.transitions else {
            throw FlowErrors.runtime(code: "flow.validate.schema_error", "gate transitions missing", stateID: state.id)
        }

        let result: FlowGateParseResult
        switch mode {
        case .live:
            guard let exec = state.exec else {
                throw FlowErrors.runtime(code: "flow.validate.schema_error", "gate exec missing", stateID: state.id)
            }
            let resolvedPath = FlowPathResolver.resolveIRRunPath(irRun: exec.run, sourcePath: ir.sourcePath)
            try FlowStepRunnerSupport.ensureReadablePath(resolvedPath, stateID: state.id)

            let scope = FlowExpressionScope(
                context: context,
                counters: counters,
                stateLast: stateLast,
                prev: prev,
                current: nil
            )
            let args = try FlowStepRunnerSupport.resolveArgs(exec.args, scope: scope)
            let env = try FlowStepRunnerSupport.resolveEnv(exec.env, scope: scope)

            let script = Script(title: state.id, path: resolvedPath, interpreter: exec.interpreter)
            let run = try await scriptRunner.run(
                script,
                options: .init(
                    args: args,
                    env: env,
                    timeoutSec: exec.timeoutSec,
                    workingDirectory: URL(fileURLWithPath: resolvedPath).deletingLastPathComponent().path
                )
            )
            if FlowStepRunnerSupport.isScriptRunTimedOut(run) {
                throw FlowErrors.runtime(
                    code: "flow.step.timeout",
                    "gate step timed out",
                    stateID: state.id
                )
            }
            if run.status != .success || run.exitCode != 0 {
                throw FlowErrors.runtime(
                    code: "flow.gate.process_exit_nonzero",
                    "gate process exited non-zero",
                    stateID: state.id
                )
            }

            do {
                result = try FlowGateOutputParser.parse(stdout: run.output, mode: exec.parse ?? .jsonLastLine)
            } catch let parseError as FlowError {
                if ir.defaults.failOnParseError {
                    throw FlowErrors.runtime(
                        code: "flow.gate.parse_error",
                        parseError.message,
                        stateID: state.id
                    )
                }
                result = FlowGateParseResult(decision: .parseError)
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

            guard case .object(let object) = item,
                  let decisionRaw = object["decision"]?.stringValue,
                  let decision = FlowGateDecision(rawValue: decisionRaw) else {
                throw FlowErrors.runtimeDryRun(
                    code: "flow.gate.parse_error",
                    "Invalid gate fixture payload for state \(state.id)",
                    stateID: state.id
                )
            }
            let retry = object["retry_after_sec"]?.intValue
            result = FlowGateParseResult(decision: decision, retryAfterSec: retry, object: object)
        }

        let transition: String?
        switch result.decision {
        case .pass:
            transition = transitions.pass
        case .needsAgent:
            transition = transitions.needsAgent
        case .wait:
            transition = transitions.wait
        case .fail:
            transition = transitions.fail
        case .parseError:
            transition = transitions.parseError
        }

        guard let next = transition else {
            throw FlowErrors.runtime(
                code: "flow.gate.parse_error",
                "parse_error transition is not configured",
                stateID: state.id
            )
        }

        return FlowGateStepResult(
            nextStateID: next,
            decision: result.decision,
            stateOutput: result.object
        )
    }
}
