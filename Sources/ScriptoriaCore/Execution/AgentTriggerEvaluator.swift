import Foundation

public enum AgentTriggerDecision: Sendable {
    case run
    case skip(reason: String)
    case invalid(reason: String)
}

public enum AgentTriggerEvaluator {
    public static func evaluate(script: Script, scriptRun: ScriptRun) -> AgentTriggerDecision {
        evaluate(mode: script.agentTriggerMode, scriptRun: scriptRun)
    }

    public static func evaluate(mode: AgentTriggerMode, scriptRun: ScriptRun) -> AgentTriggerDecision {
        switch mode {
        case .always:
            return .run
        case .preScriptTrue:
            guard let parsed = parseBooleanResult(from: scriptRun.output) else {
                return .invalid(
                    reason: "Expected script STDOUT last non-empty line to be true/false when trigger mode is preScriptTrue."
                )
            }
            if parsed {
                return .run
            }
            return .skip(reason: "Pre-script result is false.")
        }
    }

    static func parseBooleanResult(from output: String) -> Bool? {
        guard let token = lastNonEmptyLine(in: output) else { return nil }
        if let value = parseBooleanToken(token) {
            return value
        }

        guard let data = token.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }

        for key in ["triggerAgent", "agentTrigger", "shouldRunAgent", "result", "value"] {
            if let value = dictionary[key] as? Bool {
                return value
            }
            if let value = dictionary[key] as? String,
               let parsed = parseBooleanToken(value) {
                return parsed
            }
            if let value = dictionary[key] as? NSNumber {
                if value.intValue == 0 { return false }
                if value.intValue == 1 { return true }
            }
        }
        return nil
    }

    private static func lastNonEmptyLine(in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static func parseBooleanToken(_ token: String) -> Bool? {
        switch token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "1", "yes", "y", "on":
            return true
        case "false", "0", "no", "n", "off":
            return false
        default:
            return nil
        }
    }
}
