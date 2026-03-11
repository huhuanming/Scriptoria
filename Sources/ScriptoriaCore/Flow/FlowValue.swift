import Foundation

public enum FlowValue: Sendable, Equatable, Codable {
    case null
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: FlowValue])
    case array([FlowValue])

    public var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .number(let value):
            if value.rounded(.towardZero) == value {
                return Int(value)
            }
            return nil
        case .string(let value):
            return Int(value)
        default:
            return nil
        }
    }

    public subscript(key: String) -> FlowValue? {
        if case .object(let object) = self {
            return object[key]
        }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: FlowValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([FlowValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .null:
            try container.encodeNil()
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            if value.rounded(.towardZero) == value {
                try container.encode(Int(value))
            } else {
                try container.encode(value)
            }
        case .bool(let value):
            try container.encode(value)
        case .object(let object):
            try container.encode(object)
        case .array(let array):
            try container.encode(array)
        }
    }

    static func from(any raw: Any) throws -> FlowValue {
        switch raw {
        case is NSNull:
            return .null
        case let value as String:
            return .string(value)
        case let value as NSString:
            return .string(String(value))
        case let value as Int:
            return .number(Double(value))
        case let value as Int8:
            return .number(Double(value))
        case let value as Int16:
            return .number(Double(value))
        case let value as Int32:
            return .number(Double(value))
        case let value as Int64:
            return .number(Double(value))
        case let value as UInt:
            return .number(Double(value))
        case let value as UInt8:
            return .number(Double(value))
        case let value as UInt16:
            return .number(Double(value))
        case let value as UInt32:
            return .number(Double(value))
        case let value as UInt64:
            return .number(Double(value))
        case let value as Double:
            return .number(value)
        case let value as Float:
            return .number(Double(value))
        case let value as NSNumber:
            // NSNumber can represent bool/number in bridged YAML trees.
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            return .number(value.doubleValue)
        case let value as Bool:
            return .bool(value)
        case let dictionary as [String: Any]:
            var object: [String: FlowValue] = [:]
            for (key, value) in dictionary {
                object[key] = try from(any: value)
            }
            return .object(object)
        case let dictionary as [AnyHashable: Any]:
            var object: [String: FlowValue] = [:]
            for (key, value) in dictionary {
                guard let stringKey = key as? String else {
                    throw FlowErrors.schema("Object key must be string", field: nil)
                }
                object[stringKey] = try from(any: value)
            }
            return .object(object)
        case let array as [Any]:
            return .array(try array.map { try from(any: $0) })
        default:
            throw FlowErrors.schema("Unsupported value type: \(type(of: raw))")
        }
    }

    func toAny() -> Any {
        switch self {
        case .null:
            return NSNull()
        case .string(let value):
            return value
        case .number(let value):
            if value.rounded(.towardZero) == value {
                return Int(value)
            }
            return value
        case .bool(let value):
            return value
        case .object(let object):
            return object.mapValues { $0.toAny() }
        case .array(let array):
            return array.map { $0.toAny() }
        }
    }

    func lookup(path components: ArraySlice<String>) -> FlowValue? {
        guard let head = components.first else {
            return self
        }

        guard case .object(let object) = self,
              let next = object[head] else {
            return nil
        }

        return next.lookup(path: components.dropFirst())
    }
}

func flowJSONString(from value: FlowValue) throws -> String {
    switch value {
    case .string(let text):
        return text
    case .number(let number):
        if number.rounded(.towardZero) == number {
            return String(Int(number))
        }
        return String(number)
    case .bool(let flag):
        return flag ? "true" : "false"
    default:
        throw FlowErrors.runtime(code: "flow.expr.type_error", "Expression result must be scalar string/number/bool")
    }
}
