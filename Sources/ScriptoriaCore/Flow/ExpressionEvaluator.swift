import Foundation

struct FlowExpressionScope {
    var context: [String: FlowValue]
    var counters: [String: Int]
    var stateLast: [String: FlowValue]
    var prev: FlowValue?
    var current: FlowValue?
}

enum ExpressionEvaluator {
    static func evaluate(
        _ expression: String,
        scope: FlowExpressionScope,
        resolveErrorCode: String = "flow.expr.resolve_error"
    ) throws -> FlowValue {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("$.") else {
            throw FlowErrors.runtime(code: resolveErrorCode, "Invalid expression: \(expression)")
        }
        let path = String(trimmed.dropFirst(2))
        let parts = path.split(separator: ".").map(String.init)
        guard let root = parts.first else {
            throw FlowErrors.runtime(code: resolveErrorCode, "Empty expression: \(expression)")
        }

        let result: FlowValue?
        switch root {
        case "context":
            let rootValue = FlowValue.object(scope.context)
            result = rootValue.lookup(path: ArraySlice(parts.dropFirst()))

        case "counters":
            var counterObject: [String: FlowValue] = [:]
            for (key, value) in scope.counters {
                counterObject[key] = .number(Double(value))
            }
            result = FlowValue.object(counterObject).lookup(path: ArraySlice(parts.dropFirst()))

        case "state":
            guard parts.count >= 3 else {
                throw FlowErrors.runtime(code: resolveErrorCode, "Invalid state expression: \(expression)")
            }
            let stateID = parts[1]
            let cursor = parts[2]
            guard cursor == "last" else {
                throw FlowErrors.runtime(code: resolveErrorCode, "state expression must use .last")
            }
            guard let stateValue = scope.stateLast[stateID] else {
                throw FlowErrors.runtime(code: resolveErrorCode, "Missing state.last for \(stateID)")
            }
            result = stateValue.lookup(path: ArraySlice(parts.dropFirst(3)))

        case "prev":
            guard let prev = scope.prev else {
                throw FlowErrors.runtime(code: resolveErrorCode, "prev is not available")
            }
            result = prev.lookup(path: ArraySlice(parts.dropFirst()))

        case "current":
            guard let current = scope.current else {
                throw FlowErrors.runtime(code: resolveErrorCode, "current is not available")
            }
            result = current.lookup(path: ArraySlice(parts.dropFirst()))

        default:
            throw FlowErrors.runtime(code: resolveErrorCode, "Unsupported expression root: \(root)")
        }

        guard let value = result else {
            throw FlowErrors.runtime(code: resolveErrorCode, "Expression path not found: \(expression)")
        }
        return value
    }

    static func evaluateString(
        _ expression: String,
        scope: FlowExpressionScope
    ) throws -> String {
        let value = try evaluate(expression, scope: scope)
        do {
            return try flowJSONString(from: value)
        } catch {
            throw FlowErrors.runtime(code: "flow.expr.type_error", "Expression type mismatch for \(expression)")
        }
    }

    static func evaluateWaitSeconds(
        _ expression: String,
        scope: FlowExpressionScope
    ) throws -> Int {
        let value = try evaluate(
            expression,
            scope: scope,
            resolveErrorCode: "flow.wait.seconds_resolve_error"
        )

        switch value {
        case .number(let number):
            guard number.rounded(.towardZero) == number else {
                throw FlowErrors.runtime(code: "flow.wait.seconds_resolve_error", "seconds_from must resolve to integer")
            }
            let intValue = Int(number)
            guard intValue >= 0 else {
                throw FlowErrors.runtime(code: "flow.wait.seconds_resolve_error", "seconds_from must be >= 0")
            }
            return intValue

        case .string(let text):
            guard let intValue = Int(text), intValue >= 0 else {
                throw FlowErrors.runtime(code: "flow.wait.seconds_resolve_error", "seconds_from string must be decimal integer")
            }
            return intValue

        default:
            throw FlowErrors.runtime(code: "flow.wait.seconds_resolve_error", "seconds_from must resolve to integer")
        }
    }
}
