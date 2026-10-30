import Foundation

/// Addons are hand-written by third parties, so every decoder here tolerates missing fields,
/// numbers sent as strings (and vice versa) and individual malformed array elements.
extension KeyedDecodingContainer {
    func lossyString(_ key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value.isEmpty ? nil : value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return String(value) }
        return nil
    }

    func lossyInt(_ key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return Int(value) }
        if let value = try? decodeIfPresent(String.self, forKey: key) { return Int(value) }
        return nil
    }

    func lossyBool(_ key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value != 0 }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return ["true", "1", "yes"].contains(value.lowercased())
        }
        return nil
    }

    func lossyURL(_ key: Key) -> URL? {
        guard let string = lossyString(key)?.trimmingCharacters(in: .whitespaces) else { return nil }
        return URL(string: string)
    }

    /// Accepts `["a", "b"]`, `"a, b"` or a single string.
    func lossyStringArray(_ key: Key) -> [String] {
        if let values = try? decodeIfPresent([LossyElement<String>].self, forKey: key) {
            return values.compactMap(\.value).filter { !$0.isEmpty }
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return []
    }

    /// Decodes an array, dropping elements that fail to decode instead of failing the whole payload.
    func lossyArray<T: Decodable>(_ key: Key, of type: T.Type = T.self) -> [T] {
        (try? decodeIfPresent([LossyElement<T>].self, forKey: key))?.compactMap(\.value) ?? []
    }
}

struct LossyElement<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

/// Coding key usable with arbitrary string keys.
struct AnyCodingKey: CodingKey, Hashable {
    var stringValue: String
    var intValue: Int? { nil }

    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// Minimal JSON value used to keep unknown fields round-trippable (e.g. when syncing descriptors).
public enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

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
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case let .object(object) = self { return object[key] }
        return nil
    }

    public var stringValue: String? {
        switch self {
        case let .string(value): value
        case let .number(value): value.rounded() == value ? String(Int(value)) : String(value)
        default: nil
        }
    }
}

extension JSONDecoder {
    static let addon = JSONDecoder()
}

enum StremioDate {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()
    private static let lock = NSLock()

    static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return fractional.date(from: string) ?? plain.date(from: string)
    }
}
