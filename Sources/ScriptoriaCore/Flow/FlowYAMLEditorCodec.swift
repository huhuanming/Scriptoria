import Foundation
import Yams

public enum FlowYAMLEditorCodec {
    public static func loadDefinition(
        atPath path: String,
        noFSCheck: Bool = true
    ) throws -> FlowYAMLDefinition {
        try FlowValidator.validateFile(
            atPath: path,
            options: .init(checkFileSystem: !noFSCheck)
        )
    }

    public static func render(definition: FlowYAMLDefinition) throws -> String {
        let encoder = YAMLEncoder()
        encoder.options.sortKeys = false
        return try encoder.encode(EncodedFlowDefinition(from: definition))
    }

    public static func validate(
        definition: FlowYAMLDefinition,
        noFSCheck: Bool = true
    ) throws -> FlowYAMLDefinition {
        let yaml = try render(definition: definition)
        let temporaryRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let temporaryURL = temporaryRoot
            .appendingPathComponent("scriptoria-flow-editor-\(UUID().uuidString)")
            .appendingPathExtension("yaml")
        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
        do {
            try yaml.write(to: temporaryURL, atomically: true, encoding: .utf8)
            return try FlowValidator.validateFile(
                atPath: temporaryURL.path,
                options: .init(checkFileSystem: !noFSCheck)
            )
        } catch let error as FlowError {
            throw error
        } catch {
            throw FlowError(
                code: "flow.validate.schema_error",
                message: error.localizedDescription,
                phase: .validate
            )
        }
    }
}

private struct EncodedFlowDefinition: Encodable {
    var version: String
    var start: String
    var defaults: EncodedDefaults
    var context: [String: FlowValue]
    var states: [EncodedState]

    init(from definition: FlowYAMLDefinition) {
        version = definition.version
        start = definition.start
        defaults = EncodedDefaults(from: definition.defaults)
        context = definition.context
        states = definition.states.map(EncodedState.init(from:))
    }
}

private struct EncodedDefaults: Encodable {
    var maxAgentRounds: Int
    var maxWaitCycles: Int
    var maxTotalSteps: Int
    var stepTimeoutSec: Int
    var failOnParseError: Bool

    init(from defaults: FlowDefaults) {
        maxAgentRounds = defaults.maxAgentRounds
        maxWaitCycles = defaults.maxWaitCycles
        maxTotalSteps = defaults.maxTotalSteps
        stepTimeoutSec = defaults.stepTimeoutSec
        failOnParseError = defaults.failOnParseError
    }

    enum CodingKeys: String, CodingKey {
        case maxAgentRounds = "max_agent_rounds"
        case maxWaitCycles = "max_wait_cycles"
        case maxTotalSteps = "max_total_steps"
        case stepTimeoutSec = "step_timeout_sec"
        case failOnParseError = "fail_on_parse_error"
    }
}

private struct EncodedGateTransitions: Encodable {
    var pass: String
    var needsAgent: String
    var wait: String
    var fail: String
    var parseError: String?

    init(from transitions: FlowGateTransitions) {
        pass = transitions.pass
        needsAgent = transitions.needsAgent
        wait = transitions.wait
        fail = transitions.fail
        parseError = transitions.parseError
    }

    enum CodingKeys: String, CodingKey {
        case pass
        case needsAgent = "needs_agent"
        case wait
        case fail
        case parseError = "parse_error"
    }
}

private struct EncodedState: Encodable {
    var id: String
    var type: String
    var run: String?
    var task: String?
    var next: String?
    var on: EncodedGateTransitions?
    var parseMode: String?
    var timeoutSec: Int?
    var interpreter: String?
    var args: [FlowValue]?
    var env: [String: FlowValue]?
    var seconds: Int?
    var secondsFrom: String?
    var model: String?
    var counter: String?
    var maxRounds: Int?
    var prompt: String?
    var export: [String: String]?
    var status: String?
    var message: String?

    init(from state: FlowStateDefinition) {
        id = state.id
        type = state.type.rawValue
        run = state.run
        task = state.task
        next = state.next
        on = state.on.map(EncodedGateTransitions.init(from:))
        parseMode = state.parseMode?.rawValue
        timeoutSec = state.timeoutSec
        interpreter = state.interpreter?.rawValue
        args = state.args
        env = state.env
        seconds = state.seconds
        secondsFrom = state.secondsFrom
        model = state.model
        counter = state.counter
        maxRounds = state.maxRounds
        prompt = state.prompt
        export = state.export
        status = state.endStatus?.rawValue
        message = state.message
    }

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case run
        case task
        case next
        case on
        case parseMode = "parse"
        case timeoutSec = "timeout_sec"
        case interpreter
        case args
        case env
        case seconds
        case secondsFrom = "seconds_from"
        case model
        case counter
        case maxRounds = "max_rounds"
        case prompt
        case export
        case status
        case message
    }
}
