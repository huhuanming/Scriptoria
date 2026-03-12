import Foundation

struct FlowWaitStepResult {
    var nextStateID: String
    var stateOutput: [String: FlowValue]
}

struct WaitStepRunner {
    func execute(
        state: FlowIRState,
        ir: FlowIR,
        mode: FlowRunMode,
        context: [String: FlowValue],
        counters: [String: Int],
        stateLast: [String: FlowValue],
        prev: FlowValue?
    ) async throws -> FlowWaitStepResult {
        guard let wait = state.wait,
              let next = state.next else {
            throw FlowErrors.runtime(code: "flow.validate.schema_error", "wait payload missing", stateID: state.id)
        }

        let waitSeconds: Int
        if let seconds = wait.seconds {
            waitSeconds = seconds
        } else if let secondsFrom = wait.secondsFrom {
            let scope = FlowExpressionScope(
                context: context,
                counters: counters,
                stateLast: stateLast,
                prev: prev,
                current: nil
            )
            waitSeconds = try ExpressionEvaluator.evaluateWaitSeconds(secondsFrom, scope: scope)
        } else {
            throw FlowErrors.runtime(code: "flow.wait.seconds_resolve_error", "wait.seconds or wait.seconds_from required", stateID: state.id)
        }

        if waitSeconds > wait.timeoutSec {
            throw FlowErrors.runtime(code: "flow.step.timeout", "wait exceeds timeout", stateID: state.id)
        }

        if case .live = mode, waitSeconds > 0 {
            try await Task.sleep(nanoseconds: UInt64(waitSeconds) * 1_000_000_000)
        }

        return FlowWaitStepResult(
            nextStateID: next,
            stateOutput: ["seconds": .number(Double(waitSeconds))]
        )
    }
}
