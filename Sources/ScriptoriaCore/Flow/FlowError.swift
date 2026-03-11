import Foundation

public enum FlowPhase: String, Sendable, Codable {
    case validate
    case compile
    case runtimePreflight = "runtime-preflight"
    case runtime
    case runtimeDryRun = "runtime-dry-run"
}

public struct FlowError: Error, LocalizedError, Sendable {
    public var code: String
    public var message: String
    public var phase: FlowPhase
    public var stateID: String?
    public var fieldPath: String?
    public var line: Int?
    public var column: Int?

    public init(
        code: String,
        message: String,
        phase: FlowPhase,
        stateID: String? = nil,
        fieldPath: String? = nil,
        line: Int? = nil,
        column: Int? = nil
    ) {
        self.code = code
        self.message = message
        self.phase = phase
        self.stateID = stateID
        self.fieldPath = fieldPath
        self.line = line
        self.column = column
    }

    public var errorDescription: String? {
        message
    }
}

public struct FlowWarning: Sendable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

enum FlowErrors {
    static func schema(_ message: String, field: String? = nil) -> FlowError {
        FlowError(code: "flow.validate.schema_error", message: message, phase: .validate, fieldPath: field)
    }

    static func unknownField(_ field: String) -> FlowError {
        FlowError(code: "flow.validate.unknown_field", message: "Unknown field: \(field)", phase: .validate, fieldPath: field)
    }

    static func numericRange(_ message: String, field: String) -> FlowError {
        FlowError(code: "flow.validate.numeric_range_error", message: message, phase: .validate, fieldPath: field)
    }

    static func fieldType(_ message: String, field: String) -> FlowError {
        FlowError(code: "flow.validate.field_type_error", message: message, phase: .validate, fieldPath: field)
    }

    static func pathKind(
        _ run: String,
        phase: FlowPhase,
        stateID: String? = nil,
        fieldPath: String? = "run"
    ) -> FlowError {
        FlowError(
            code: "flow.path.invalid_path_kind",
            message: "Invalid run path token '\(run)'. Use an explicit path literal.",
            phase: phase,
            stateID: stateID,
            fieldPath: fieldPath
        )
    }

    static func pathNotFound(
        _ path: String,
        phase: FlowPhase,
        stateID: String? = nil,
        fieldPath: String? = nil
    ) -> FlowError {
        FlowError(
            code: "flow.path.not_found",
            message: "Script path not found or unreadable: \(path)",
            phase: phase,
            stateID: stateID,
            fieldPath: fieldPath
        )
    }

    static func parseModeInvalid(_ mode: String, fieldPath: String = "parse", stateID: String? = nil) -> FlowError {
        FlowError(
            code: "flow.gate.parse_mode_invalid",
            message: "Unsupported gate parse mode: \(mode)",
            phase: .validate,
            stateID: stateID,
            fieldPath: fieldPath
        )
    }

    static func unreachable(_ stateID: String) -> FlowError {
        FlowError(code: "flow.validate.unreachable_state", message: "Unreachable state: \(stateID)", phase: .validate, stateID: stateID)
    }

    static func runtime(code: String, _ message: String, stateID: String? = nil, field: String? = nil) -> FlowError {
        FlowError(code: code, message: message, phase: .runtime, stateID: stateID, fieldPath: field)
    }

    static func runtimePreflight(from error: FlowError) -> FlowError {
        FlowError(
            code: error.code,
            message: error.message,
            phase: .runtimePreflight,
            stateID: error.stateID,
            fieldPath: error.fieldPath,
            line: error.line,
            column: error.column
        )
    }

    static func runtimeDryRun(code: String, _ message: String, stateID: String? = nil) -> FlowError {
        FlowError(code: code, message: message, phase: .runtimeDryRun, stateID: stateID)
    }
}
