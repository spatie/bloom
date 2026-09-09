import Foundation

// MARK: - JSONValue

/// A closed representation of any JSON document.
///
/// Tool input is arbitrary JSON that Bloom neither controls nor fully understands, so it has to
/// survive a round trip untouched. Modelling it as an enum rather than `Any` keeps it `Sendable`,
/// keeps it out of the dynamic-cast business, and lets a renderer written a year from now dig
/// into a payload nobody thought to decode today.
public enum JSONValue: Sendable, Hashable, Codable {
    case string(String)
    /// A whole number that fits in `Int`. Kept apart from `.number` because `Double` silently
    /// rewrites anything past 2^53: `9007199254740993` comes back as `...992`, which is not the
    /// raw JSON the store promises to hand back.
    case integer(Int)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    /// How deep a document may nest before it is refused.
    ///
    /// Decoding recurses once per level, and a Swift concurrency thread has a small stack: a line
    /// nested two hundred deep took the whole process down with a stack overflow, which no line
    /// off a subprocess gets to do. Real payloads sit around ten levels deep, tool input included,
    /// so this is far out of the way of anything the CLI actually emits.
    public static let maximumNesting = 64

    public init(from decoder: Decoder) throws {
        let counter = decoder.userInfo[Self.depthKey] as? DepthCounter
        let depth = counter?.depth ?? decoder.codingPath.count
        guard depth < Self.maximumNesting else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "JSON nested deeper than \(Self.maximumNesting) levels"
            ))
        }
        counter?.depth = depth + 1
        defer { counter?.depth = depth }

        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        // Integer first: a `Double` round trip is lossy above 2^53, and token counts, durations
        // and exit codes are all integers to begin with.
        if let value = try? container.decode(Int.self) { self = .integer(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([JSONValue].self) { self = .array(value); return }
        if let value = try? container.decode([String: JSONValue].self) { self = .object(value); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Counts nesting for one decode. `Decoder.codingPath` answers the same question, but it
    /// rebuilds an array on every value, which is not something to do once per byte of a hook
    /// payload. It is still the fallback for a decoder Bloom did not build itself.
    /// Unchecked because a decode is single threaded: the counter is created in `parse`, used by
    /// that one decoder, and dropped when it returns. It never crosses a thread.
    private final class DepthCounter: @unchecked Sendable {
        var depth = 0
    }

    private static let depthKey = CodingUserInfoKey(rawValue: "be.spatie.bloom.jsonDepth")!

    /// Parse one JSON document. Returns nil instead of throwing, because every caller in Bloom is
    /// on a path that must never abort the stream. Documents nested past `maximumNesting` are
    /// refused the same way malformed bytes are.
    public static func parse(_ data: Data) -> JSONValue? {
        let decoder = JSONDecoder()
        decoder.userInfo[depthKey] = DepthCounter()
        return try? decoder.decode(JSONValue.self, from: data)
    }

    public static func parse(_ text: String) -> JSONValue? {
        parse(Data(text.utf8))
    }

    // MARK: Accessors

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        switch self {
        case .integer(let value): Double(value)
        case .number(let value): value
        default: nil
        }
    }

    /// Nil rather than a trap for anything `Int` cannot hold. A single valid `thinking_tokens`
    /// line carrying `1e100` used to kill the process here, and no line off a subprocess is ever
    /// allowed to do that.
    public var intValue: Int? {
        switch self {
        case .integer(let value): value
        case .number(let value): Int(exactly: value.rounded(.towardZero))
        default: nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// A JSON `null` reads as a missing key, because for every field Bloom cares about the two
    /// mean the same thing (`is_error` and `parent_tool_use_id` are explicitly null constantly).
    public subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self, let value = object[key], !value.isNull else { return nil }
        return value
    }

    public subscript(index: Int) -> JSONValue? {
        guard case .array(let array) = self, array.indices.contains(index) else { return nil }
        return array[index]
    }

    /// Strings out of an array, skipping anything that is not one. Used for the tool and slash
    /// command lists on the init event.
    public var stringArray: [String] {
        (arrayValue ?? []).compactMap(\.stringValue)
    }

    /// Human-readable JSON, for showing a tool input that has no bespoke renderer yet.
    public var prettyPrinted: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
