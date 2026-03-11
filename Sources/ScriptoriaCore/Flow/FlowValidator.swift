import Foundation
import Yams

public enum FlowValidator {
    public static func validateFile(
        atPath path: String,
        options: FlowValidationOptions = .init()
    ) throws -> FlowYAMLDefinition {
        let absolutePath = FlowPathResolver.absolutePath(from: path)
        let sourceURL = URL(fileURLWithPath: absolutePath)
        let yamlText: String
        do {
            yamlText = try String(contentsOf: sourceURL, encoding: .utf8)
        } catch {
            throw FlowErrors.schema("Unable to read flow file: \(absolutePath)")
        }

        let locationIndex = FlowSourceLocationIndex(yamlText: yamlText)
        do {
            return try validateDefinition(
                yamlText: yamlText,
                sourceURL: sourceURL,
                options: options
            )
        } catch let error as FlowError {
            throw locationIndex.enrich(error)
        }
    }

    // MARK: - Internal Entry

    private static func validateDefinition(
        yamlText: String,
        sourceURL: URL,
        options: FlowValidationOptions
    ) throws -> FlowYAMLDefinition {
        let rootAny: Any
        do {
            rootAny = try Yams.load(yaml: yamlText) as Any
        } catch {
            throw FlowErrors.schema("YAML parse failed: \(error.localizedDescription)")
        }

        guard let root = rootAny as? [String: Any] else {
            throw FlowErrors.schema("Top-level YAML must be an object")
        }

        let allowedTopFields: Set<String> = ["version", "start", "defaults", "context", "states"]
        for key in root.keys where !allowedTopFields.contains(key) {
            throw FlowErrors.unknownField(key)
        }

        guard let version = root["version"] as? String else {
            throw FlowErrors.schema("Missing required field: version", field: "version")
        }
        guard version == "flow/v1" else {
            throw FlowErrors.schema("Unsupported flow version: \(version)", field: "version")
        }

        guard let start = root["start"] as? String, !start.isEmpty else {
            throw FlowErrors.schema("Missing required field: start", field: "start")
        }

        let defaults = try parseDefaults(root["defaults"])
        let context = try parseContext(root["context"])

        guard let statesRaw = root["states"] else {
            throw FlowErrors.schema("Missing required field: states", field: "states")
        }

        guard let statesArray = statesRaw as? [Any] else {
            throw FlowErrors.schema("states must be an array", field: "states")
        }
        if statesArray.isEmpty {
            throw FlowErrors.schema("states must not be empty", field: "states")
        }

        var states: [FlowStateDefinition] = []
        states.reserveCapacity(statesArray.count)

        for (index, raw) in statesArray.enumerated() {
            guard let stateObject = raw as? [String: Any] else {
                throw FlowErrors.schema("State at index \(index) must be an object", field: "states[\(index)]")
            }
            states.append(try parseState(stateObject, index: index))
        }

        try validateSemantics(
            start: start,
            states: states,
            defaults: defaults,
            sourceURL: sourceURL,
            options: options
        )

        return FlowYAMLDefinition(
            version: version,
            start: start,
            defaults: defaults,
            context: context,
            states: states
        )
    }

    // MARK: - Parsing

    private static func parseDefaults(_ raw: Any?) throws -> FlowDefaults {
        guard let raw else {
            return FlowDefaults()
        }
        guard let object = raw as? [String: Any] else {
            throw FlowErrors.schema("defaults must be an object", field: "defaults")
        }

        let allowed: Set<String> = [
            "max_agent_rounds",
            "max_wait_cycles",
            "max_total_steps",
            "step_timeout_sec",
            "fail_on_parse_error"
        ]
        for key in object.keys where !allowed.contains(key) {
            throw FlowErrors.unknownField("defaults.\(key)")
        }

        var defaults = FlowDefaults()
        if let value = object["max_agent_rounds"] {
            defaults.maxAgentRounds = try parseInt(value, field: "defaults.max_agent_rounds", min: 1)
        }
        if let value = object["max_wait_cycles"] {
            defaults.maxWaitCycles = try parseInt(value, field: "defaults.max_wait_cycles", min: 1)
        }
        if let value = object["max_total_steps"] {
            defaults.maxTotalSteps = try parseInt(value, field: "defaults.max_total_steps", min: 1)
        }
        if let value = object["step_timeout_sec"] {
            defaults.stepTimeoutSec = try parseInt(value, field: "defaults.step_timeout_sec", min: 1)
        }
        if let value = object["fail_on_parse_error"] {
            guard let flag = value as? Bool else {
                throw FlowErrors.schema("defaults.fail_on_parse_error must be a boolean", field: "defaults.fail_on_parse_error")
            }
            defaults.failOnParseError = flag
        }
        return defaults
    }

    private static func parseContext(_ raw: Any?) throws -> [String: FlowValue] {
        guard let raw else { return [:] }
        guard let object = raw as? [String: Any] else {
            throw FlowErrors.schema("context must be an object", field: "context")
        }

        var context: [String: FlowValue] = [:]
        for (key, value) in object {
            context[key] = try FlowValue.from(any: value)
        }
        return context
    }

    private static func parseState(_ object: [String: Any], index: Int) throws -> FlowStateDefinition {
        guard let id = object["id"] as? String, !id.isEmpty else {
            throw FlowErrors.schema("State at index \(index) missing id", field: "states[\(index)].id")
        }
        guard let typeRaw = object["type"] as? String,
              let type = FlowStateType(rawValue: typeRaw) else {
            throw FlowErrors.schema("State '\(id)' has invalid type", field: "states[\(index)].type")
        }

        let allowedFields = allowedFields(for: type)
        for key in object.keys where !allowedFields.contains(key) {
            throw FlowErrors.unknownField("states.\(id).\(key)")
        }

        var state = FlowStateDefinition(id: id, type: type)

        if let run = object["run"] as? String {
            state.run = run
        }
        if let task = object["task"] as? String {
            state.task = task
        }
        if let next = object["next"] as? String {
            state.next = next
        }
        if let timeout = object["timeout_sec"] {
            state.timeoutSec = try parseInt(timeout, field: "states.\(id).timeout_sec", min: 1)
        }

        if let interpreterRaw = object["interpreter"] as? String {
            guard let interpreter = Interpreter(rawValue: interpreterRaw) else {
                throw FlowErrors.schema("Invalid interpreter: \(interpreterRaw)", field: "states.\(id).interpreter")
            }
            state.interpreter = interpreter
        }

        if let argsRaw = object["args"] {
            guard let list = argsRaw as? [Any] else {
                throw FlowErrors.schema("args must be an array", field: "states.\(id).args")
            }
            state.args = try list.map { try FlowValue.from(any: $0) }
        }

        if let envRaw = object["env"] {
            guard let envObject = envRaw as? [String: Any] else {
                throw FlowErrors.schema("env must be an object", field: "states.\(id).env")
            }
            var env: [String: FlowValue] = [:]
            for (key, value) in envObject {
                env[key] = try FlowValue.from(any: value)
            }
            state.env = env
        }

        if let onRaw = object["on"] {
            guard let onObject = onRaw as? [String: Any] else {
                throw FlowErrors.schema("on must be an object", field: "states.\(id).on")
            }
            let allowedOn: Set<String> = ["pass", "needs_agent", "wait", "fail", "parse_error"]
            for key in onObject.keys where !allowedOn.contains(key) {
                throw FlowErrors.unknownField("states.\(id).on.\(key)")
            }
            guard let pass = onObject["pass"] as? String,
                  let needsAgent = onObject["needs_agent"] as? String,
                  let wait = onObject["wait"] as? String,
                  let fail = onObject["fail"] as? String else {
                throw FlowErrors.schema("gate.on must include pass/needs_agent/wait/fail", field: "states.\(id).on")
            }
            let parseError = onObject["parse_error"] as? String
            state.on = FlowGateTransitions(
                pass: pass,
                needsAgent: needsAgent,
                wait: wait,
                fail: fail,
                parseError: parseError
            )
        }

        if let parseRaw = object["parse"] as? String {
            guard let mode = FlowGateParseMode(rawValue: parseRaw) else {
                throw FlowErrors.parseModeInvalid(
                    parseRaw,
                    fieldPath: "states.\(id).parse",
                    stateID: id
                )
            }
            state.parseMode = mode
        }

        if let value = object["seconds"] {
            state.seconds = try parseInt(value, field: "states.\(id).seconds", min: 0)
        }
        if let secondsFrom = object["seconds_from"] as? String {
            state.secondsFrom = secondsFrom
        }

        if let model = object["model"] as? String {
            state.model = model
        }
        if let counter = object["counter"] as? String {
            state.counter = counter
        }
        if let maxRounds = object["max_rounds"] {
            state.maxRounds = try parseInt(maxRounds, field: "states.\(id).max_rounds", min: 1)
        }
        if let prompt = object["prompt"] as? String {
            state.prompt = prompt
        }

        if let exportRaw = object["export"] {
            guard let exportObject = exportRaw as? [String: Any] else {
                throw FlowErrors.schema("export must be an object", field: "states.\(id).export")
            }
            var export: [String: String] = [:]
            for (key, value) in exportObject {
                guard let expr = value as? String else {
                    throw FlowErrors.schema("export value must be string expression", field: "states.\(id).export.\(key)")
                }
                export[key] = expr
            }
            state.export = export
        }

        if let statusRaw = object["status"] as? String {
            guard let status = FlowEndStatus(rawValue: statusRaw) else {
                throw FlowErrors.schema("Invalid end status: \(statusRaw)", field: "states.\(id).status")
            }
            state.endStatus = status
        }
        if let message = object["message"] as? String {
            state.message = message
        }

        return state
    }

    private static func allowedFields(for type: FlowStateType) -> Set<String> {
        switch type {
        case .gate:
            return ["id", "type", "run", "args", "env", "interpreter", "timeout_sec", "parse", "on"]
        case .agent:
            return ["id", "type", "task", "next", "model", "counter", "max_rounds", "prompt", "export", "timeout_sec"]
        case .wait:
            return ["id", "type", "next", "seconds", "seconds_from", "timeout_sec"]
        case .script:
            return ["id", "type", "run", "next", "args", "env", "interpreter", "timeout_sec", "export"]
        case .end:
            return ["id", "type", "status", "message"]
        }
    }

    private static func parseInt(_ raw: Any, field: String, min: Int) throws -> Int {
        let parsed: Int?
        switch raw {
        case let value as Int:
            parsed = value
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                parsed = nil
            } else if value.doubleValue.rounded(.towardZero) == value.doubleValue {
                parsed = value.intValue
            } else {
                parsed = nil
            }
        case let value as Double:
            if value.rounded(.towardZero) == value {
                parsed = Int(value)
            } else {
                parsed = nil
            }
        case let value as String:
            parsed = Int(value)
        default:
            parsed = nil
        }

        guard let number = parsed else {
            throw FlowErrors.numericRange("\(field) must be an integer", field: field)
        }
        guard number >= min else {
            throw FlowErrors.numericRange("\(field) must be >= \(min)", field: field)
        }
        return number
    }

    // MARK: - Semantics

    private static func validateSemantics(
        start: String,
        states: [FlowStateDefinition],
        defaults: FlowDefaults,
        sourceURL: URL,
        options: FlowValidationOptions
    ) throws {
        var ids = Set<String>()
        for state in states {
            if ids.contains(state.id) {
                throw FlowErrors.schema("Duplicate state id: \(state.id)", field: "states")
            }
            ids.insert(state.id)
        }

        guard ids.contains(start) else {
            throw FlowErrors.schema("start state not found: \(start)", field: "start")
        }

        for state in states {
            try validateStateFields(state, defaults: defaults, sourceURL: sourceURL, options: options)
        }

        for state in states {
            switch state.type {
            case .gate:
                if let on = state.on {
                    try ensureTargetExists(on.pass, ids: ids, stateID: state.id)
                    try ensureTargetExists(on.needsAgent, ids: ids, stateID: state.id)
                    try ensureTargetExists(on.wait, ids: ids, stateID: state.id)
                    try ensureTargetExists(on.fail, ids: ids, stateID: state.id)
                    if let parseError = on.parseError {
                        try ensureTargetExists(parseError, ids: ids, stateID: state.id)
                    }
                }
            case .wait, .agent, .script:
                if let next = state.next {
                    try ensureTargetExists(next, ids: ids, stateID: state.id)
                }
            case .end:
                break
            }
        }

        try validateReachability(start: start, states: states)
    }

    private static func validateStateFields(
        _ state: FlowStateDefinition,
        defaults: FlowDefaults,
        sourceURL: URL,
        options: FlowValidationOptions
    ) throws {
        let flowDir = sourceURL.deletingLastPathComponent()
        switch state.type {
        case .gate:
            guard let run = state.run, !run.isEmpty else {
                throw FlowErrors.schema("gate state requires run", field: "states.\(state.id).run")
            }
            _ = try FlowPathResolver.resolveRunPath(
                run,
                flowDirectory: flowDir,
                phase: .validate,
                checkFileSystem: options.checkFileSystem,
                stateID: state.id
            )
            guard state.on != nil else {
                throw FlowErrors.schema("gate state requires on", field: "states.\(state.id).on")
            }
            if !defaults.failOnParseError, state.on?.parseError == nil {
                throw FlowErrors.schema(
                    "gate.on.parse_error is required when fail_on_parse_error=false",
                    field: "states.\(state.id).on.parse_error"
                )
            }
            try validateArgsEnv(state: state)

        case .script:
            guard let run = state.run, !run.isEmpty else {
                throw FlowErrors.schema("script state requires run", field: "states.\(state.id).run")
            }
            _ = try FlowPathResolver.resolveRunPath(
                run,
                flowDirectory: flowDir,
                phase: .validate,
                checkFileSystem: options.checkFileSystem,
                stateID: state.id
            )
            guard let next = state.next, !next.isEmpty else {
                throw FlowErrors.schema("script state requires next", field: "states.\(state.id).next")
            }
            _ = next
            try validateArgsEnv(state: state)
            try validateExport(state: state)

        case .agent:
            guard let task = state.task, !task.isEmpty else {
                throw FlowErrors.schema("agent state requires task", field: "states.\(state.id).task")
            }
            _ = task
            guard let next = state.next, !next.isEmpty else {
                throw FlowErrors.schema("agent state requires next", field: "states.\(state.id).next")
            }
            _ = next
            if let maxRounds = state.maxRounds, maxRounds < 1 {
                throw FlowErrors.numericRange("max_rounds must be >= 1", field: "states.\(state.id).max_rounds")
            }
            try validateExport(state: state)

        case .wait:
            guard let next = state.next, !next.isEmpty else {
                throw FlowErrors.schema("wait state requires next", field: "states.\(state.id).next")
            }
            _ = next
            if state.seconds == nil && state.secondsFrom == nil {
                throw FlowErrors.schema("wait requires one of seconds or seconds_from", field: "states.\(state.id)")
            }
            if state.seconds != nil && state.secondsFrom != nil {
                throw FlowErrors.schema("wait cannot specify both seconds and seconds_from", field: "states.\(state.id)")
            }
            if let seconds = state.seconds, seconds < 0 {
                throw FlowErrors.numericRange("wait.seconds must be >= 0", field: "states.\(state.id).seconds")
            }
            if let secondsFrom = state.secondsFrom {
                try validateExpression(secondsFrom)
            }

        case .end:
            guard state.endStatus != nil else {
                throw FlowErrors.schema("end state requires status", field: "states.\(state.id).status")
            }
        }

        if let timeout = state.timeoutSec, timeout < 1 {
            throw FlowErrors.numericRange("timeout_sec must be >= 1", field: "states.\(state.id).timeout_sec")
        }
    }

    private static func validateArgsEnv(state: FlowStateDefinition) throws {
        if let args = state.args {
            for value in args {
                try validateStringFieldValue(
                    value,
                    field: "states.\(state.id).args",
                    allowExpression: true
                )
            }
        }

        if let env = state.env {
            for (key, value) in env {
                try validateStringFieldValue(
                    value,
                    field: "states.\(state.id).env.\(key)",
                    allowExpression: true
                )
            }
        }
    }

    private static func validateExport(state: FlowStateDefinition) throws {
        guard let export = state.export else { return }
        for (key, expr) in export {
            try validateExpression(expr, field: "states.\(state.id).export.\(key)")
        }
    }

    private static func validateStringFieldValue(
        _ value: FlowValue,
        field: String,
        allowExpression: Bool
    ) throws {
        switch value {
        case .string(let text):
            if allowExpression, isExpression(text) {
                try validateExpression(text, field: field)
            }
        case .number, .bool:
            break
        case .null, .array, .object:
            throw FlowErrors.fieldType("\(field) only accepts string/number/bool literals", field: field)
        }
    }

    static func isExpression(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("$.")
    }

    static func validateExpression(_ expression: String, field: String = "expression") throws {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("$.") else {
            throw FlowErrors.schema("Expression must start with '$.'", field: field)
        }
        let path = String(trimmed.dropFirst(2))
        let parts = path.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else {
            throw FlowErrors.schema("Expression path is empty", field: field)
        }
        if parts.contains(where: { $0.isEmpty }) {
            throw FlowErrors.schema("Expression contains empty path segment", field: field)
        }

        let root = parts[0]
        switch root {
        case "context", "counters", "prev", "current":
            return

        case "state":
            guard parts.count >= 3 else {
                throw FlowErrors.schema("state expression must be $.state.<state_id>.last", field: field)
            }
            guard parts[2] == "last" else {
                throw FlowErrors.schema("state expression must use .last", field: field)
            }
            return

        default:
            throw FlowErrors.schema("Expression prefix is not supported", field: field)
        }
    }

    private static func ensureTargetExists(_ target: String, ids: Set<String>, stateID: String) throws {
        guard ids.contains(target) else {
            throw FlowErrors.schema("State '\(stateID)' targets unknown state '\(target)'", field: "states.\(stateID)")
        }
    }

    private static func validateReachability(start: String, states: [FlowStateDefinition]) throws {
        var adjacency: [String: [String]] = [:]
        for state in states {
            switch state.type {
            case .gate:
                let targets = [
                    state.on?.pass,
                    state.on?.needsAgent,
                    state.on?.wait,
                    state.on?.fail,
                    state.on?.parseError
                ].compactMap { $0 }
                adjacency[state.id] = targets
            case .wait, .agent, .script:
                adjacency[state.id] = state.next.map { [$0] } ?? []
            case .end:
                adjacency[state.id] = []
            }
        }

        var visited = Set<String>()
        var queue = [start]

        while !queue.isEmpty {
            let current = queue.removeFirst()
            if !visited.insert(current).inserted {
                continue
            }
            let targets = adjacency[current] ?? []
            for target in targets where !visited.contains(target) {
                queue.append(target)
            }
        }

        for state in states where !visited.contains(state.id) {
            throw FlowErrors.unreachable(state.id)
        }
    }
}

private struct FlowSourceLocationIndex {
    private struct FieldLocation {
        var line: Int
        var keyColumn: Int
        var valueColumn: Int?
    }

    private struct SourceLocation {
        var line: Int
        var column: Int
    }

    private struct StateLocation {
        var startLine: Int
        var startColumn: Int
        var id: String?
        var fields: [String: FieldLocation]
        var nested: [String: [String: FieldLocation]]
    }

    private let topLevel: [String: FieldLocation]
    private let topNested: [String: [String: FieldLocation]]
    private let statesByID: [String: StateLocation]
    private let statesByIndex: [Int: StateLocation]

    init(yamlText: String) {
        var topLevel: [String: FieldLocation] = [:]
        var topNested: [String: [String: FieldLocation]] = [:]
        var states: [StateLocation] = []

        let lines = yamlText.components(separatedBy: .newlines)

        var activeTopParent: String?
        var activeTopParentIndent = 0
        var inStates = false
        var statesIndent = 0

        var currentStateIndex: Int?
        var currentStateIndent = 0
        var activeStateParent: String?
        var activeStateParentIndent = 0

        for (zeroBasedLine, rawLine) in lines.enumerated() {
            let lineNo = zeroBasedLine + 1
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            let indent = rawLine.prefix { $0 == " " }.count

            if indent == 0, let record = parseYAMLKeyRecord(from: rawLine) {
                let key = record.key
                inStates = key == "states"
                statesIndent = 0

                let location = FieldLocation(
                    line: lineNo,
                    keyColumn: record.keyColumn,
                    valueColumn: record.valueColumn
                )
                topLevel[key] = topLevel[key] ?? location

                if key == "defaults" || key == "context" {
                    activeTopParent = key
                    activeTopParentIndent = indent
                } else {
                    activeTopParent = nil
                }

                if !inStates {
                    currentStateIndex = nil
                    activeStateParent = nil
                }
                continue
            }

            if let parent = activeTopParent {
                if indent > activeTopParentIndent,
                   let record = parseYAMLKeyRecord(from: rawLine),
                   !trimmed.hasPrefix("- ")
                {
                    let subKey = record.key
                    var nested = topNested[parent] ?? [:]
                    let location = FieldLocation(
                        line: lineNo,
                        keyColumn: record.keyColumn,
                        valueColumn: record.valueColumn
                    )
                    nested[subKey] = nested[subKey] ?? location
                    topNested[parent] = nested
                } else if indent <= activeTopParentIndent {
                    activeTopParent = nil
                }
            }

            if inStates {
                if trimmed.hasPrefix("- "), indent > statesIndent {
                    let index = states.count
                    let startColumn = rawLine.firstIndex(of: "-").map {
                        rawLine.distance(from: rawLine.startIndex, to: $0) + 1
                    } ?? (indent + 1)
                    states.append(
                        StateLocation(
                            startLine: lineNo,
                            startColumn: startColumn,
                            id: nil,
                            fields: [:],
                            nested: [:]
                        )
                    )
                    currentStateIndex = index
                    currentStateIndent = indent
                    activeStateParent = nil

                    if let record = parseYAMLKeyRecord(from: rawLine) {
                        let key = record.key
                        let location = FieldLocation(
                            line: lineNo,
                            keyColumn: record.keyColumn,
                            valueColumn: record.valueColumn
                        )
                        states[index].fields[key] = states[index].fields[key] ?? location
                        if key == "id", let id = parseYAMLScalarValue(from: rawLine) {
                            states[index].id = id
                        }
                    }
                    continue
                }

                guard let stateIndex = currentStateIndex else {
                    continue
                }

                if indent <= currentStateIndent {
                    activeStateParent = nil
                    continue
                }

                if let record = parseYAMLKeyRecord(from: rawLine), !trimmed.hasPrefix("- ") {
                    let key = record.key
                    let location = FieldLocation(
                        line: lineNo,
                        keyColumn: record.keyColumn,
                        valueColumn: record.valueColumn
                    )
                    if indent <= currentStateIndent + 2 {
                        states[stateIndex].fields[key] = states[stateIndex].fields[key] ?? location
                        if key == "id", let id = parseYAMLScalarValue(from: rawLine) {
                            states[stateIndex].id = id
                        }

                        if key == "on" || key == "env" || key == "export" {
                            activeStateParent = key
                            activeStateParentIndent = indent
                        } else {
                            activeStateParent = nil
                        }
                    } else if let parent = activeStateParent, indent > activeStateParentIndent {
                        var nested = states[stateIndex].nested[parent] ?? [:]
                        nested[key] = nested[key] ?? location
                        states[stateIndex].nested[parent] = nested
                    }
                } else if indent <= activeStateParentIndent {
                    activeStateParent = nil
                }
            }
        }

        var byID: [String: StateLocation] = [:]
        var byIndex: [Int: StateLocation] = [:]
        for (index, state) in states.enumerated() {
            byIndex[index] = state
            if let id = state.id, byID[id] == nil {
                byID[id] = state
            }
        }

        self.topLevel = topLevel
        self.topNested = topNested
        self.statesByID = byID
        self.statesByIndex = byIndex
    }

    func enrich(_ error: FlowError) -> FlowError {
        if error.line != nil, error.column != nil {
            return error
        }

        var enriched = error
        if let location = locate(error: error, fieldPath: error.fieldPath, stateID: error.stateID) {
            if enriched.line == nil {
                enriched.line = location.line
            }
            if enriched.column == nil {
                enriched.column = location.column
            }
        }
        return enriched
    }

    private func locate(error: FlowError, fieldPath: String?, stateID: String?) -> SourceLocation? {
        guard let fieldLocation = locateFieldLocation(fieldPath: fieldPath, stateID: stateID) else {
            return nil
        }
        return SourceLocation(
            line: fieldLocation.line,
            column: preferredColumn(for: error, location: fieldLocation)
        )
    }

    private func locateFieldLocation(fieldPath: String?, stateID: String?) -> FieldLocation? {
        if let fieldPath, fieldPath.hasPrefix("states[") {
            let components = fieldPath.components(separatedBy: "].")
            if let head = components.first,
               let open = head.firstIndex(of: "["),
               let index = Int(head[head.index(after: open)...]) {
                if let state = statesByIndex[index] {
                    let rest = components.count > 1 ? components[1] : ""
                    return stateLocation(state: state, restPath: rest)
                }
            }
        }

        if let fieldPath, fieldPath.hasPrefix("states.") {
            let parts = fieldPath.split(separator: ".").map(String.init)
            if parts.count >= 2 {
                let id = parts[1]
                if let state = statesByID[id] {
                    let rest = parts.dropFirst(2).joined(separator: ".")
                    return stateLocation(state: state, restPath: rest)
                }
            }
        }

        if let stateID, let state = statesByID[stateID] {
            if let fieldPath {
                if fieldPath == "run", let location = state.fields["run"] {
                    return location
                }
                if let direct = state.fields[fieldPath] {
                    return direct
                }
                if let nested = nestedLocation(state: state, path: fieldPath) {
                    return nested
                }
            }
            return FieldLocation(
                line: state.startLine,
                keyColumn: state.startColumn,
                valueColumn: nil
            )
        }

        if let fieldPath {
            let parts = fieldPath.split(separator: ".").map(String.init)
            if let first = parts.first {
                if parts.count == 1 {
                    return topLevel[first]
                }
                if first == "defaults" || first == "context" {
                    if let second = parts.dropFirst().first {
                        if let location = topNested[first]?[second] {
                            return location
                        }
                    }
                    return topLevel[first]
                }
            }
        }

        return nil
    }

    private func stateLocation(state: StateLocation, restPath: String) -> FieldLocation? {
        if restPath.isEmpty {
            return FieldLocation(
                line: state.startLine,
                keyColumn: state.startColumn,
                valueColumn: nil
            )
        }

        let parts = restPath.split(separator: ".").map(String.init)
        guard let head = parts.first else {
            return FieldLocation(
                line: state.startLine,
                keyColumn: state.startColumn,
                valueColumn: nil
            )
        }

        if parts.count == 1 {
            return state.fields[head] ?? FieldLocation(
                line: state.startLine,
                keyColumn: state.startColumn,
                valueColumn: nil
            )
        }

        if let nested = state.nested[head], let second = parts.dropFirst().first {
            return nested[second] ?? state.fields[head] ?? FieldLocation(
                line: state.startLine,
                keyColumn: state.startColumn,
                valueColumn: nil
            )
        }

        return state.fields[head] ?? FieldLocation(
            line: state.startLine,
            keyColumn: state.startColumn,
            valueColumn: nil
        )
    }

    private func nestedLocation(state: StateLocation, path: String) -> FieldLocation? {
        let parts = path.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return nil }
        let parent = parts[0]
        let child = parts[1]
        return state.nested[parent]?[child]
    }

    private func preferredColumn(for error: FlowError, location: FieldLocation) -> Int {
        if shouldPreferValueColumn(error), let valueColumn = location.valueColumn {
            return valueColumn
        }
        return location.keyColumn
    }

    private func shouldPreferValueColumn(_ error: FlowError) -> Bool {
        switch error.code {
        case "flow.validate.unknown_field", "flow.validate.unreachable_state":
            return false
        case "flow.path.invalid_path_kind",
             "flow.path.not_found",
             "flow.gate.parse_mode_invalid",
             "flow.validate.numeric_range_error",
             "flow.validate.field_type_error":
            return true
        default:
            break
        }

        guard error.code == "flow.validate.schema_error" else {
            return false
        }

        let message = error.message.lowercased()
        if message.contains("missing required field")
            || message.contains("requires run")
            || message.contains("requires next")
            || message.contains("requires task")
            || message.contains("requires status")
            || message.contains("gate state requires on")
            || message.contains("wait requires one of")
            || message.contains("wait cannot specify both")
        {
            return false
        }

        if message.contains("unsupported flow version")
            || message.contains("start state not found")
            || message.contains("invalid end status")
            || message.contains("invalid interpreter")
            || message.contains("has invalid type")
            || message.contains("must be")
            || message.contains("unsupported")
            || message.contains("invalid")
        {
            return true
        }

        return false
    }
}

private struct YAMLKeyRecord {
    var key: String
    var keyColumn: Int
    var valueColumn: Int?
}

private func parseYAMLKeyRecord(from rawLine: String) -> YAMLKeyRecord? {
    let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed.hasPrefix("#") {
        return nil
    }

    var cursor = rawLine.startIndex
    while cursor < rawLine.endIndex, rawLine[cursor] == " " {
        cursor = rawLine.index(after: cursor)
    }

    if cursor < rawLine.endIndex, rawLine[cursor] == "-" {
        let next = rawLine.index(after: cursor)
        if next < rawLine.endIndex, rawLine[next] == " " {
            cursor = rawLine.index(after: next)
            while cursor < rawLine.endIndex, rawLine[cursor] == " " {
                cursor = rawLine.index(after: cursor)
            }
        }
    }

    let keyStart = cursor
    guard keyStart < rawLine.endIndex,
          let colon = rawLine[keyStart...].firstIndex(of: ":") else {
        return nil
    }

    let key = String(rawLine[keyStart..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard isValidYAMLKey(key) else {
        return nil
    }

    var valueColumn: Int?
    var valueStart = rawLine.index(after: colon)
    while valueStart < rawLine.endIndex, rawLine[valueStart] == " " {
        valueStart = rawLine.index(after: valueStart)
    }
    if valueStart < rawLine.endIndex, rawLine[valueStart] != "#" {
        valueColumn = rawLine.distance(from: rawLine.startIndex, to: valueStart) + 1
    }

    let keyColumn = rawLine.distance(from: rawLine.startIndex, to: keyStart) + 1
    return YAMLKeyRecord(key: key, keyColumn: keyColumn, valueColumn: valueColumn)
}

private func isValidYAMLKey(_ key: String) -> Bool {
    guard !key.isEmpty else { return false }
    let first = key[key.startIndex]
    guard (first >= "A" && first <= "Z")
            || (first >= "a" && first <= "z")
            || first == "_" else {
        return false
    }
    for char in key.dropFirst() {
        let isAlpha = (char >= "A" && char <= "Z") || (char >= "a" && char <= "z")
        let isDigit = (char >= "0" && char <= "9")
        if !(isAlpha || isDigit || char == "_") {
            return false
        }
    }
    return true
}

private func parseYAMLScalarValue(from line: String) -> String? {
    let source = line.trimmingCharacters(in: .whitespacesAndNewlines)
    let working: String
    if source.hasPrefix("- ") {
        working = String(source.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
        working = source
    }
    guard let colon = working.firstIndex(of: ":") else {
        return nil
    }
    var value = String(working[working.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
    if value.isEmpty {
        return nil
    }
    if let commentStart = value.range(of: " #") {
        value = String(value[..<commentStart.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
        value = String(value.dropFirst().dropLast())
    } else if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
        value = String(value.dropFirst().dropLast())
    }
    return value.isEmpty ? nil : value
}
