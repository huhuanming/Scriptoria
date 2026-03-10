import Foundation

public enum AgentCommandMode: String, Codable, CaseIterable, Sendable {
    case prompt
    case interrupt
}

public enum AgentCommandInput: Equatable, Sendable {
    case steer(String)
    case interrupt

    public static func parseCLI(_ input: String) -> AgentCommandInput? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.lowercased() == "/interrupt" {
            return .interrupt
        }
        return .steer(trimmed)
    }

    public static func from(mode: AgentCommandMode, input: String) -> AgentCommandInput? {
        switch mode {
        case .prompt:
            return parseCLI(input)
        case .interrupt:
            return .interrupt
        }
    }
}

