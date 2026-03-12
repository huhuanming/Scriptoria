import Foundation

struct FlowScriptStepResult {
    var nextStateID: String
    var stateOutput: [String: FlowValue]
}

struct ScriptStepRunner {
    let scriptRunner: ScriptRunner

    func execute(
        state: FlowIRState,
        ir: FlowIR,
        mode: FlowRunMode,
        dryFixture: inout FlowDryRunFixture?,
        context: inout [String: FlowValue],
        counters: [String: Int],
        stateLast: [String: FlowValue],
        prev: FlowValue?
    ) async throws -> FlowScriptStepResult {
        guard let next = state.next else {
            throw FlowErrors.runtime(code: "flow.validate.schema_error", "script next missing", stateID: state.id)
        }

        var stateOutput: [String: FlowValue] = [:]
        switch mode {
        case .live:
            guard let exec = state.exec else {
                throw FlowErrors.runtime(code: "flow.validate.schema_error", "script exec missing", stateID: state.id)
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
                    "script step timed out",
                    stateID: state.id
                )
            }
            if run.status != .success || run.exitCode != 0 {
                throw FlowErrors.runtime(
                    code: "flow.script.process_exit_nonzero",
                    "script process exited non-zero",
                    stateID: state.id
                )
            }

            stateOutput["stdout"] = .string(run.output)
            stateOutput["stderr"] = .string(run.errorOutput)
            if let lastLine = FlowStepRunnerSupport.lastNonEmptyLine(in: run.output) {
                stateOutput["stdout_last_line"] = .string(lastLine)
            }

            if let export = state.export {
                guard let final = try FlowStepRunnerSupport.parseLastLineJSONObject(text: run.output) else {
                    throw FlowErrors.runtime(
                        code: "flow.script.output_parse_error",
                        "script export requires final JSON line",
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
                    missingCode: "flow.script.export_field_missing",
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
                throw FlowErrors.runtimeDryRun(
                    code: "flow.validate.schema_error",
                    "script fixture entry must be object",
                    stateID: state.id
                )
            }
            stateOutput = object

            if let status = object["status"]?.stringValue,
               status == "failed" {
                throw FlowErrors.runtime(code: "flow.script.process_exit_nonzero", "script fixture indicated failure", stateID: state.id)
            }

            if let export = state.export {
                guard case .object(let final)? = object["final"] else {
                    throw FlowErrors.runtime(
                        code: "flow.script.output_parse_error",
                        "script export requires final JSON object",
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
                    missingCode: "flow.script.export_field_missing",
                    stateID: state.id
                )
            }
        }

        return FlowScriptStepResult(nextStateID: next, stateOutput: stateOutput)
    }
}
