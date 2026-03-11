import Foundation

public struct FlowGateParseResult: Sendable, Equatable {
    public var decision: FlowGateDecision
    public var retryAfterSec: Int?
    public var object: [String: FlowValue]

    public init(decision: FlowGateDecision, retryAfterSec: Int? = nil, object: [String: FlowValue] = [:]) {
        self.decision = decision
        self.retryAfterSec = retryAfterSec
        self.object = object
    }
}

public enum FlowGateOutputParser {
    public static func parse(stdout: String, mode: FlowGateParseMode) throws -> FlowGateParseResult {
        let jsonText: String
        switch mode {
        case .jsonLastLine:
            guard let line = stdout
                .split(whereSeparator: \.isNewline)
                .map({ String($0).trimmingCharacters(in: .whitespacesAndNewlines) })
                .last(where: { !$0.isEmpty }) else {
                throw FlowErrors.runtime(code: "flow.gate.parse_error", "gate output has no JSON line")
            }
            jsonText = line
        case .jsonFullStdout:
            jsonText = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let data = jsonText.data(using: .utf8) else {
            throw FlowErrors.runtime(code: "flow.gate.parse_error", "gate output is not valid UTF-8")
        }
        let rawObject: Any
        do {
            rawObject = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw FlowErrors.runtime(code: "flow.gate.parse_error", "gate output JSON parse failed")
        }

        guard let object = rawObject as? [String: Any] else {
            throw FlowErrors.runtime(code: "flow.gate.parse_error", "gate JSON must be an object")
        }
        guard let decisionRaw = object["decision"] as? String,
              let decision = FlowGateDecision(rawValue: decisionRaw) else {
            throw FlowErrors.runtime(code: "flow.gate.parse_error", "gate JSON missing valid decision")
        }

        var parsedObject: [String: FlowValue] = [:]
        for (key, value) in object {
            parsedObject[key] = try FlowValue.from(any: value)
        }

        let retryAfter: Int?
        if let value = object["retry_after_sec"] {
            switch value {
            case let number as Int:
                retryAfter = number
            case let number as NSNumber:
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    throw FlowErrors.runtime(code: "flow.gate.parse_error", "retry_after_sec must be integer")
                }
                if number.doubleValue.rounded(.towardZero) != number.doubleValue {
                    throw FlowErrors.runtime(code: "flow.gate.parse_error", "retry_after_sec must be integer")
                }
                retryAfter = number.intValue
            case let text as String:
                guard let parsed = Int(text) else {
                    throw FlowErrors.runtime(code: "flow.gate.parse_error", "retry_after_sec must be integer")
                }
                retryAfter = parsed
            default:
                throw FlowErrors.runtime(code: "flow.gate.parse_error", "retry_after_sec must be integer")
            }
        } else {
            retryAfter = nil
        }

        return FlowGateParseResult(decision: decision, retryAfterSec: retryAfter, object: parsedObject)
    }
}
