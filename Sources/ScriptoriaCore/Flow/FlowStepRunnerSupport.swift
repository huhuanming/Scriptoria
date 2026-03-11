import Foundation

enum FlowStepRunnerSupport {
    static func resolveArgs(_ args: [String], scope: FlowExpressionScope) throws -> [String] {
        try args.map { value in
            if FlowValidator.isExpression(value) {
                return try ExpressionEvaluator.evaluateString(value, scope: scope)
            }
            return value
        }
    }

    static func resolveEnv(_ env: [String: String], scope: FlowExpressionScope) throws -> [String: String] {
        var resolved: [String: String] = [:]
        for (key, value) in env {
            if FlowValidator.isExpression(value) {
                resolved[key] = try ExpressionEvaluator.evaluateString(value, scope: scope)
            } else {
                resolved[key] = value
            }
        }
        return resolved
    }

    static func applyExport(
        _ export: [String: String],
        context: inout [String: FlowValue],
        counters: [String: Int],
        stateLast: [String: FlowValue],
        prev: FlowValue?,
        current: FlowValue,
        missingCode: String,
        stateID: String
    ) throws {
        for key in export.keys.sorted() {
            guard let expression = export[key] else { continue }
            do {
                let scope = FlowExpressionScope(
                    context: context,
                    counters: counters,
                    stateLast: stateLast,
                    prev: prev,
                    current: current
                )
                let value = try ExpressionEvaluator.evaluate(expression, scope: scope)
                context[key] = value
            } catch let error as FlowError {
                if error.code == "flow.expr.resolve_error" {
                    throw FlowErrors.runtime(code: missingCode, "Export field missing for key \(key)", stateID: stateID)
                }
                throw error
            }
        }
    }

    static func parseLastLineJSONObject(text: String) throws -> [String: FlowValue]? {
        guard let last = lastNonEmptyLine(in: text) else {
            return nil
        }
        guard let data = last.data(using: .utf8) else {
            return nil
        }
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            return nil
        }
        guard let object = raw as? [String: Any] else {
            return nil
        }
        var result: [String: FlowValue] = [:]
        for (key, value) in object {
            result[key] = try FlowValue.from(any: value)
        }
        return result
    }

    static func lastNonEmptyLine(in text: String) -> String? {
        text
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .last(where: { !$0.isEmpty })
    }

    static func ensureReadablePath(_ path: String, stateID: String) throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        if !exists || isDirectory.boolValue || !FileManager.default.isReadableFile(atPath: path) {
            throw FlowErrors.pathNotFound(
                path,
                phase: .runtime,
                stateID: stateID,
                fieldPath: "states.\(stateID).run"
            )
        }
    }

    static func isScriptRunTimedOut(_ run: ScriptRun) -> Bool {
        run.errorOutput.contains("Script timed out after")
    }

    static func waitForAgentCompletion(
        session: PostScriptAgentSession,
        timeoutSec: Int,
        graceSec: Int,
        stateID: String
    ) async throws -> AgentExecutionResult {
        enum Outcome {
            case completed(AgentExecutionResult)
            case timedOut
        }

        let outcome: Outcome
        do {
            outcome = try await withThrowingTaskGroup(of: Outcome.self) { group in
                group.addTask {
                    let result = try await session.waitForCompletion()
                    return .completed(result)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeoutSec) * 1_000_000_000)
                    return .timedOut
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
        } catch {
            throw FlowErrors.runtime(code: "flow.agent.failed", "Agent execution failed: \(error.localizedDescription)", stateID: stateID)
        }

        switch outcome {
        case .completed(let result):
            return result

        case .timedOut:
            try? await session.interrupt()

            _ = try? await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    _ = try await session.waitForCompletion()
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(graceSec) * 1_000_000_000)
                }
                _ = try await group.next()
                group.cancelAll()
            }

            await session.close()
            throw FlowErrors.runtime(code: "flow.step.timeout", "Agent step timed out", stateID: stateID)
        }
    }
}

actor FlowInterruptMarker {
    private var interruptedByUser = false

    func markInterrupted() {
        interruptedByUser = true
    }

    func isInterrupted() -> Bool {
        interruptedByUser
    }
}
