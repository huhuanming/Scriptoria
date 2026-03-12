import Foundation

public struct FlowDryRunFixture: Sendable, Equatable {
    public var states: [String: [FlowValue]]

    public init(states: [String: [FlowValue]]) {
        self.states = states
    }

    public static func load(fromPath path: String) throws -> FlowDryRunFixture {
        let absolute = FlowPathResolver.absolutePath(from: path)
        let data = try Data(contentsOf: URL(fileURLWithPath: absolute))
        let raw = try JSONSerialization.jsonObject(with: data, options: [])
        guard let root = raw as? [String: Any] else {
            throw FlowErrors.runtimeDryRun(code: "flow.validate.schema_error", "fixture root must be object")
        }
        guard let statesRaw = root["states"] as? [String: Any] else {
            throw FlowErrors.runtimeDryRun(code: "flow.validate.schema_error", "fixture.states must be object")
        }

        var states: [String: [FlowValue]] = [:]
        for (stateID, itemsRaw) in statesRaw {
            guard let itemsArray = itemsRaw as? [Any] else {
                throw FlowErrors.runtimeDryRun(
                    code: "flow.validate.schema_error",
                    "fixture.states.\(stateID) must be an array"
                )
            }
            states[stateID] = try itemsArray.map { try FlowValue.from(any: $0) }
        }

        return FlowDryRunFixture(states: states)
    }

    mutating func consume(stateID: String) -> FlowValue? {
        guard var entries = states[stateID], !entries.isEmpty else {
            return nil
        }
        let first = entries.removeFirst()
        states[stateID] = entries
        return first
    }

    func remainingCount(for stateID: String) -> Int {
        states[stateID]?.count ?? 0
    }
}
