import Foundation

public enum FlowCompiler {
    public static func compileFile(
        atPath path: String,
        options: FlowCompileOptions = .init()
    ) throws -> FlowIR {
        let absolutePath = FlowPathResolver.absolutePath(from: path)
        let sourceURL = URL(fileURLWithPath: absolutePath)

        let definition = try FlowValidator.validateFile(
            atPath: absolutePath,
            options: .init(checkFileSystem: options.checkFileSystem)
        )

        var states: [FlowIRState] = []
        states.reserveCapacity(definition.states.count)

        for state in definition.states {
            states.append(
                try compileState(
                    state,
                    defaults: definition.defaults,
                    sourceURL: sourceURL,
                    checkFileSystem: options.checkFileSystem
                )
            )
        }

        return FlowIR(
            version: "flow-ir/v1",
            start: definition.start,
            defaults: definition.defaults,
            context: definition.context,
            states: states,
            sourcePath: absolutePath
        )
    }

    public static func renderCanonicalJSON(ir: FlowIR) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(ir)
        guard let text = String(data: data, encoding: .utf8) else {
            throw FlowError(
                code: "flow.validate.schema_error",
                message: "Failed to encode IR JSON as UTF-8 text",
                phase: .compile
            )
        }
        return text
    }

    private static func compileState(
        _ state: FlowStateDefinition,
        defaults: FlowDefaults,
        sourceURL: URL,
        checkFileSystem: Bool
    ) throws -> FlowIRState {
        switch state.type {
        case .gate:
            let runRaw = try required(state.run, message: "gate.run required", field: "states.\(state.id).run")
            let resolved = try FlowPathResolver.resolveRunPath(
                runRaw,
                flowDirectory: sourceURL.deletingLastPathComponent(),
                phase: .compile,
                checkFileSystem: checkFileSystem,
                stateID: state.id
            )
            let transitions = try required(state.on, message: "gate.on required", field: "states.\(state.id).on")
            var ir = FlowIRState(id: state.id, kind: .gate)
            ir.exec = FlowIRExec(
                run: resolved.irPath,
                args: try compileArgs(state.args, field: "states.\(state.id).args"),
                env: try compileEnv(state.env, fieldPrefix: "states.\(state.id).env"),
                parse: state.parseMode ?? .jsonLastLine,
                interpreter: state.interpreter ?? .auto,
                timeoutSec: state.timeoutSec ?? defaults.stepTimeoutSec
            )
            ir.transitions = FlowIRTransitions(
                pass: transitions.pass,
                needsAgent: transitions.needsAgent,
                wait: transitions.wait,
                fail: transitions.fail,
                parseError: transitions.parseError
            )
            return ir

        case .script:
            let runRaw = try required(state.run, message: "script.run required", field: "states.\(state.id).run")
            let resolved = try FlowPathResolver.resolveRunPath(
                runRaw,
                flowDirectory: sourceURL.deletingLastPathComponent(),
                phase: .compile,
                checkFileSystem: checkFileSystem,
                stateID: state.id
            )
            let next = try required(state.next, message: "script.next required", field: "states.\(state.id).next")
            var ir = FlowIRState(id: state.id, kind: .script)
            ir.exec = FlowIRExec(
                run: resolved.irPath,
                args: try compileArgs(state.args, field: "states.\(state.id).args"),
                env: try compileEnv(state.env, fieldPrefix: "states.\(state.id).env"),
                parse: nil,
                interpreter: state.interpreter ?? .auto,
                timeoutSec: state.timeoutSec ?? defaults.stepTimeoutSec
            )
            ir.export = state.export
            ir.next = next
            return ir

        case .agent:
            let task = try required(state.task, message: "agent.task required", field: "states.\(state.id).task")
            let next = try required(state.next, message: "agent.next required", field: "states.\(state.id).next")
            let counter = state.counter ?? "agent_round.\(state.id)"
            let maxRounds = state.maxRounds ?? defaults.maxAgentRounds
            var ir = FlowIRState(id: state.id, kind: .agent)
            ir.agent = FlowIRAgent(
                task: task,
                model: state.model,
                counter: counter,
                maxRounds: maxRounds,
                prompt: state.prompt,
                timeoutSec: state.timeoutSec ?? defaults.stepTimeoutSec
            )
            ir.export = state.export
            ir.next = next
            return ir

        case .wait:
            let next = try required(state.next, message: "wait.next required", field: "states.\(state.id).next")
            var ir = FlowIRState(id: state.id, kind: .wait)
            ir.wait = FlowIRWait(
                seconds: state.seconds,
                secondsFrom: state.secondsFrom,
                timeoutSec: state.timeoutSec ?? defaults.stepTimeoutSec
            )
            ir.next = next
            return ir

        case .end:
            let status = try required(state.endStatus, message: "end.status required", field: "states.\(state.id).status")
            var ir = FlowIRState(id: state.id, kind: .end)
            ir.end = FlowIREnd(status: status, message: state.message)
            return ir
        }
    }

    private static func compileArgs(_ args: [FlowValue]?, field: String) throws -> [String] {
        guard let args else { return [] }
        return try args.map { try compileStringField($0, field: field) }
    }

    private static func compileEnv(_ env: [String: FlowValue]?, fieldPrefix: String) throws -> [String: String] {
        guard let env else { return [:] }
        var compiled: [String: String] = [:]
        for key in env.keys.sorted() {
            guard let value = env[key] else { continue }
            compiled[key] = try compileStringField(value, field: "\(fieldPrefix).\(key)")
        }
        return compiled
    }

    private static func compileStringField(_ value: FlowValue, field: String) throws -> String {
        switch value {
        case .string(let text):
            if FlowValidator.isExpression(text) {
                try FlowValidator.validateExpression(text, field: field)
            }
            return text
        case .number(let number):
            if number.rounded(.towardZero) == number {
                return String(Int(number))
            }
            return String(number)
        case .bool(let flag):
            return flag ? "true" : "false"
        case .null, .array, .object:
            throw FlowErrors.fieldType("\(field) only accepts string/number/bool", field: field)
        }
    }

    private static func required<T>(_ value: T?, message: String, field: String) throws -> T {
        guard let value else {
            throw FlowErrors.schema(message, field: field)
        }
        return value
    }
}
