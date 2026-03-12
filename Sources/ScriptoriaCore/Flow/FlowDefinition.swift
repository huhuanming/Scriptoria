import Foundation

public enum FlowStateType: String, Sendable, Codable {
    case gate
    case agent
    case wait
    case script
    case end
}

public enum FlowGateParseMode: String, Sendable, Codable {
    case jsonLastLine = "json_last_line"
    case jsonFullStdout = "json_full_stdout"
}

public enum FlowGateDecision: String, Sendable, Codable {
    case pass
    case needsAgent = "needs_agent"
    case wait
    case fail
    case parseError = "parse_error"
}

public enum FlowEndStatus: String, Sendable, Codable {
    case success
    case failure
}

public struct FlowDefaults: Sendable, Codable, Equatable {
    public var maxAgentRounds: Int
    public var maxWaitCycles: Int
    public var maxTotalSteps: Int
    public var stepTimeoutSec: Int
    public var failOnParseError: Bool

    public init(
        maxAgentRounds: Int = 20,
        maxWaitCycles: Int = 200,
        maxTotalSteps: Int = 2000,
        stepTimeoutSec: Int = 1800,
        failOnParseError: Bool = true
    ) {
        self.maxAgentRounds = maxAgentRounds
        self.maxWaitCycles = maxWaitCycles
        self.maxTotalSteps = maxTotalSteps
        self.stepTimeoutSec = stepTimeoutSec
        self.failOnParseError = failOnParseError
    }
}

public struct FlowGateTransitions: Sendable, Codable, Equatable {
    public var pass: String
    public var needsAgent: String
    public var wait: String
    public var fail: String
    public var parseError: String?

    public init(pass: String, needsAgent: String, wait: String, fail: String, parseError: String? = nil) {
        self.pass = pass
        self.needsAgent = needsAgent
        self.wait = wait
        self.fail = fail
        self.parseError = parseError
    }
}

public struct FlowStateDefinition: Sendable, Codable, Equatable {
    public var id: String
    public var type: FlowStateType

    public var run: String?
    public var task: String?
    public var next: String?
    public var on: FlowGateTransitions?

    public var parseMode: FlowGateParseMode?
    public var timeoutSec: Int?
    public var interpreter: Interpreter?

    public var args: [FlowValue]?
    public var env: [String: FlowValue]?

    public var seconds: Int?
    public var secondsFrom: String?

    public var model: String?
    public var counter: String?
    public var maxRounds: Int?
    public var prompt: String?

    public var export: [String: String]?

    public var endStatus: FlowEndStatus?
    public var message: String?

    public init(id: String, type: FlowStateType) {
        self.id = id
        self.type = type
    }
}

public struct FlowYAMLDefinition: Sendable, Codable, Equatable {
    public var version: String
    public var start: String
    public var defaults: FlowDefaults
    public var context: [String: FlowValue]
    public var states: [FlowStateDefinition]

    public init(
        version: String,
        start: String,
        defaults: FlowDefaults,
        context: [String: FlowValue],
        states: [FlowStateDefinition]
    ) {
        self.version = version
        self.start = start
        self.defaults = defaults
        self.context = context
        self.states = states
    }
}

public enum FlowIRStateKind: String, Sendable, Codable {
    case gate
    case agent
    case wait
    case script
    case end
}

public struct FlowIRExec: Sendable, Codable, Equatable {
    public var run: String
    public var args: [String]
    public var env: [String: String]
    public var parse: FlowGateParseMode?
    public var interpreter: Interpreter
    public var timeoutSec: Int

    public init(
        run: String,
        args: [String] = [],
        env: [String: String] = [:],
        parse: FlowGateParseMode? = nil,
        interpreter: Interpreter = .auto,
        timeoutSec: Int
    ) {
        self.run = run
        self.args = args
        self.env = env
        self.parse = parse
        self.interpreter = interpreter
        self.timeoutSec = timeoutSec
    }

    enum CodingKeys: String, CodingKey {
        case run
        case args
        case env
        case parse
        case interpreter
        case timeoutSec = "timeout_sec"
    }
}

public struct FlowIRTransitions: Sendable, Codable, Equatable {
    public var pass: String
    public var needsAgent: String
    public var wait: String
    public var fail: String
    public var parseError: String?

    public init(pass: String, needsAgent: String, wait: String, fail: String, parseError: String? = nil) {
        self.pass = pass
        self.needsAgent = needsAgent
        self.wait = wait
        self.fail = fail
        self.parseError = parseError
    }

    enum CodingKeys: String, CodingKey {
        case pass
        case needsAgent = "needs_agent"
        case wait
        case fail
        case parseError = "parse_error"
    }
}

public struct FlowIRAgent: Sendable, Codable, Equatable {
    public var task: String
    public var model: String?
    public var counter: String
    public var maxRounds: Int
    public var prompt: String?
    public var timeoutSec: Int

    public init(
        task: String,
        model: String? = nil,
        counter: String,
        maxRounds: Int,
        prompt: String? = nil,
        timeoutSec: Int
    ) {
        self.task = task
        self.model = model
        self.counter = counter
        self.maxRounds = maxRounds
        self.prompt = prompt
        self.timeoutSec = timeoutSec
    }

    enum CodingKeys: String, CodingKey {
        case task
        case model
        case counter
        case maxRounds = "max_rounds"
        case prompt
        case timeoutSec = "timeout_sec"
    }
}

public struct FlowIRWait: Sendable, Codable, Equatable {
    public var seconds: Int?
    public var secondsFrom: String?
    public var timeoutSec: Int

    public init(seconds: Int? = nil, secondsFrom: String? = nil, timeoutSec: Int) {
        self.seconds = seconds
        self.secondsFrom = secondsFrom
        self.timeoutSec = timeoutSec
    }

    enum CodingKeys: String, CodingKey {
        case seconds
        case secondsFrom = "seconds_from"
        case timeoutSec = "timeout_sec"
    }
}

public struct FlowIREnd: Sendable, Codable, Equatable {
    public var status: FlowEndStatus
    public var message: String?

    public init(status: FlowEndStatus, message: String? = nil) {
        self.status = status
        self.message = message
    }
}

public struct FlowIRState: Sendable, Codable, Equatable {
    public var id: String
    public var kind: FlowIRStateKind

    public var exec: FlowIRExec?
    public var transitions: FlowIRTransitions?

    public var agent: FlowIRAgent?
    public var wait: FlowIRWait?
    public var next: String?
    public var export: [String: String]?

    public var end: FlowIREnd?

    public init(id: String, kind: FlowIRStateKind) {
        self.id = id
        self.kind = kind
    }
}

public struct FlowIR: Sendable, Encodable, Equatable {
    public var version: String
    public var start: String
    public var defaults: FlowDefaults
    public var context: [String: FlowValue]
    public var states: [FlowIRState]

    // Needed for runtime path resolution.
    public var sourcePath: String

    public init(
        version: String,
        start: String,
        defaults: FlowDefaults,
        context: [String: FlowValue],
        states: [FlowIRState],
        sourcePath: String
    ) {
        self.version = version
        self.start = start
        self.defaults = defaults
        self.context = context
        self.states = states
        self.sourcePath = sourcePath
    }

    enum CodingKeys: String, CodingKey {
        case version
        case start
        case defaults
        case context
        case states
    }

    public func stateMap() -> [String: FlowIRState] {
        var map: [String: FlowIRState] = [:]
        for state in states {
            map[state.id] = state
        }
        return map
    }
}

public struct FlowValidationOptions: Sendable {
    public var checkFileSystem: Bool

    public init(checkFileSystem: Bool = true) {
        self.checkFileSystem = checkFileSystem
    }
}

public struct FlowCompileOptions: Sendable {
    public var checkFileSystem: Bool

    public init(checkFileSystem: Bool = true) {
        self.checkFileSystem = checkFileSystem
    }
}
