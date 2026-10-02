import Foundation

/// Newline-delimited JSON protocol shared by the daemon, CLI, and GUI.
public enum IPC {
    public struct Frame: Codable, Sendable {
        public var method: String
        public var id: Int
        public var params: [String: JSONValue]

        public init(method: String, id: Int = 1, params: [String: JSONValue] = [:]) {
            self.method = method
            self.id = id
            self.params = params
        }
    }

    public struct Response: Codable, Sendable {
        public var ok: Bool
        public var id: Int
        public var data: JSONValue?
        public var error: String?

        public init(ok: Bool, id: Int, data: JSONValue? = nil, error: String? = nil) {
            self.ok = ok
            self.id = id
            self.data = data
            self.error = error
        }
    }

    public static let encoder: JSONEncoder = JSONEncoder()
    public static let decoder: JSONDecoder = JSONDecoder()

    public static func encodeFrame<T: Encodable>(_ value: T) -> Data {
        var data = (try? encoder.encode(value)) ?? Data()
        data.append(0x0A)
        return data
    }
}

/// A flexible JSON value used in IPC request and response payloads.
public indirect enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public static func encode<T: Encodable>(_ value: T) -> JSONValue {
        guard let data = try? IPC.encoder.encode(value),
              let result = try? IPC.decoder.decode(JSONValue.self, from: data) else { return .null }
        return result
    }

    public var stringValue: String? {
        switch self { case .string(let value): return value; case .int(let value): return String(value); case .double(let value): return String(value); default: return nil }
    }
    public var intValue: Int? {
        switch self { case .int(let value): return value; case .double(let value): return Int(value); case .string(let value): return Int(value); default: return nil }
    }
    public var doubleValue: Double? {
        switch self { case .double(let value): return value; case .int(let value): return Double(value); case .string(let value): return Double(value); default: return nil }
    }
    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }; return nil
    }
}
