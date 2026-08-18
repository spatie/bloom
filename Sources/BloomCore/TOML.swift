import Foundation

/// A TOML value, reduced to what a settings file actually contains.
public indirect enum TOMLValue: Sendable, Equatable {
    case string(String)
    case integer(Int)
    case double(Double)
    case boolean(Bool)
    case array([TOMLValue])
    case table([String: TOMLValue])

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .integer(let value): value
        case .double(let value): Int(value)
        default: nil
        }
    }

    public var boolValue: Bool? {
        if case .boolean(let value) = self { return value }
        return nil
    }

    public var arrayValue: [TOMLValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var tableValue: [String: TOMLValue]? {
        if case .table(let value) = self { return value }
        return nil
    }

    public var stringArray: [String]? {
        arrayValue?.compactMap(\.stringValue)
    }

    /// Dotted lookup: `settings["scripts.run.dev.command"]`.
    public subscript(path: String) -> TOMLValue? {
        var current: TOMLValue? = self
        for component in path.components(separatedBy: ".") {
            guard let table = current?.tableValue else { return nil }
            current = table[component]
        }
        return current
    }
}

public struct TOMLError: Error, CustomStringConvertible {
    public let message: String
    public let line: Int
    public var description: String { "TOML line \(line): \(message)" }
}

/// A parser for the subset of TOML that settings files use: tables, arrays of tables, dotted
/// keys, the four string forms, numbers, booleans, arrays and inline tables. No dates.
public enum TOML {
    public static func parse(_ source: String) throws -> TOMLValue {
        var parser = Parser(source: Array(source.unicodeScalars))
        return try parser.parse()
    }

    public static func parse(contentsOf path: String) throws -> TOMLValue? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return try parse(String(contentsOfFile: path, encoding: .utf8))
    }

    private struct Parser {
        let source: [Unicode.Scalar]
        var index = 0
        var line = 1
        var root: [String: TOMLValue] = [:]
        var currentPath: [String] = []

        init(source: [Unicode.Scalar]) {
            self.source = source
        }

        mutating func parse() throws -> TOMLValue {
            while true {
                skipWhitespaceAndComments()
                guard index < source.count else { break }

                if peek() == "[" {
                    try parseTableHeader()
                } else {
                    let (path, value) = try parseKeyValue()
                    insert(value, at: currentPath + path)
                }
            }
            return .table(root)
        }

        // MARK: - Cursor

        func peek(_ offset: Int = 0) -> Unicode.Scalar? {
            let target = index + offset
            return target < source.count ? source[target] : nil
        }

        mutating func advance() -> Unicode.Scalar? {
            guard index < source.count else { return nil }
            let scalar = source[index]
            index += 1
            if scalar == "\n" { line += 1 }
            return scalar
        }

        mutating func expect(_ scalar: Unicode.Scalar) throws {
            guard peek() == scalar else {
                throw TOMLError(message: "expected \(scalar)", line: line)
            }
            _ = advance()
        }

        mutating func skipInlineWhitespace() {
            while let scalar = peek(), scalar == " " || scalar == "\t" { _ = advance() }
        }

        mutating func skipWhitespaceAndComments() {
            while let scalar = peek() {
                if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" {
                    _ = advance()
                } else if scalar == "#" {
                    while let next = peek(), next != "\n" { _ = advance() }
                } else {
                    break
                }
            }
        }

        mutating func skipToEndOfLine() throws {
            skipInlineWhitespace()
            if peek() == "#" {
                while let next = peek(), next != "\n" { _ = advance() }
            }
            if let scalar = peek(), scalar != "\n", scalar != "\r" {
                throw TOMLError(message: "unexpected trailing content \(scalar)", line: line)
            }
        }

        // MARK: - Structure

        mutating func parseTableHeader() throws {
            try expect("[")
            let isArrayOfTables = peek() == "["
            if isArrayOfTables { _ = advance() }

            var path: [String] = []
            repeat {
                skipInlineWhitespace()
                path.append(try parseKeyComponent())
                skipInlineWhitespace()
                if peek() == "." { _ = advance() } else { break }
            } while true

            try expect("]")
            if isArrayOfTables { try expect("]") }
            try skipToEndOfLine()

            currentPath = path

            if isArrayOfTables {
                appendTable(at: path)
            } else if valueAt(path) == nil {
                insert(.table([:]), at: path)
            }
        }

        mutating func parseKeyValue() throws -> ([String], TOMLValue) {
            var path: [String] = []
            repeat {
                skipInlineWhitespace()
                path.append(try parseKeyComponent())
                skipInlineWhitespace()
                if peek() == "." { _ = advance() } else { break }
            } while true

            try expect("=")
            skipInlineWhitespace()
            let value = try parseValue()
            try skipToEndOfLine()
            return (path, value)
        }

        mutating func parseKeyComponent() throws -> String {
            guard let scalar = peek() else {
                throw TOMLError(message: "unexpected end of file in key", line: line)
            }
            if scalar == "\"" || scalar == "'" {
                return try parseString()
            }
            var name = ""
            while let next = peek(), isBareKeyScalar(next) {
                name.unicodeScalars.append(next)
                _ = advance()
            }
            guard !name.isEmpty else {
                throw TOMLError(message: "empty key", line: line)
            }
            return name
        }

        func isBareKeyScalar(_ scalar: Unicode.Scalar) -> Bool {
            CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-"
        }

        // MARK: - Values

        mutating func parseValue() throws -> TOMLValue {
            guard let scalar = peek() else {
                throw TOMLError(message: "expected a value", line: line)
            }
            switch scalar {
            case "\"", "'": return .string(try parseString())
            case "[": return try parseArray()
            case "{": return try parseInlineTable()
            default: return try parseScalar()
            }
        }

        mutating func parseString() throws -> String {
            guard let quote = peek() else {
                throw TOMLError(message: "expected a string", line: line)
            }
            let isMultiline = peek(1) == quote && peek(2) == quote

            if isMultiline {
                _ = advance(); _ = advance(); _ = advance()
                // A newline immediately after the opening delimiter is trimmed.
                if peek() == "\r" { _ = advance() }
                if peek() == "\n" { _ = advance() }

                var result = ""
                while true {
                    guard let scalar = peek() else {
                        throw TOMLError(message: "unterminated multiline string", line: line)
                    }
                    if scalar == quote, peek(1) == quote, peek(2) == quote {
                        _ = advance(); _ = advance(); _ = advance()
                        return result
                    }
                    if quote == "\"", scalar == "\\" {
                        _ = advance()
                        // Line-ending backslash swallows the following whitespace.
                        if peek() == "\n" || peek() == "\r" {
                            while let next = peek(), next == "\n" || next == "\r" || next == " " || next == "\t" {
                                _ = advance()
                            }
                            continue
                        }
                        result.unicodeScalars.append(try parseEscape())
                        continue
                    }
                    result.unicodeScalars.append(scalar)
                    _ = advance()
                }
            }

            _ = advance()
            var result = ""
            while true {
                guard let scalar = peek() else {
                    throw TOMLError(message: "unterminated string", line: line)
                }
                if scalar == quote {
                    _ = advance()
                    return result
                }
                if scalar == "\n" {
                    throw TOMLError(message: "newline in single-line string", line: line)
                }
                if quote == "\"", scalar == "\\" {
                    _ = advance()
                    result.unicodeScalars.append(try parseEscape())
                    continue
                }
                result.unicodeScalars.append(scalar)
                _ = advance()
            }
        }

        mutating func parseEscape() throws -> Unicode.Scalar {
            guard let scalar = advance() else {
                throw TOMLError(message: "unterminated escape", line: line)
            }
            switch scalar {
            case "n": return "\n"
            case "t": return "\t"
            case "r": return "\r"
            case "\"": return "\""
            case "\\": return "\\"
            case "b": return Unicode.Scalar(8)
            case "f": return Unicode.Scalar(12)
            case "0": return Unicode.Scalar(0)
            case "u", "U":
                let width = scalar == "u" ? 4 : 8
                var hex = ""
                for _ in 0..<width {
                    guard let next = advance() else {
                        throw TOMLError(message: "truncated unicode escape", line: line)
                    }
                    hex.unicodeScalars.append(next)
                }
                guard let code = UInt32(hex, radix: 16), let value = Unicode.Scalar(code) else {
                    throw TOMLError(message: "invalid unicode escape \\\(hex)", line: line)
                }
                return value
            default:
                throw TOMLError(message: "unknown escape \\\(scalar)", line: line)
            }
        }

        mutating func parseArray() throws -> TOMLValue {
            try expect("[")
            var values: [TOMLValue] = []
            while true {
                skipWhitespaceAndComments()
                if peek() == "]" { _ = advance(); break }
                values.append(try parseValue())
                skipWhitespaceAndComments()
                if peek() == "," {
                    _ = advance()
                } else if peek() == "]" {
                    _ = advance(); break
                } else {
                    throw TOMLError(message: "expected , or ] in array", line: line)
                }
            }
            return .array(values)
        }

        mutating func parseInlineTable() throws -> TOMLValue {
            try expect("{")
            var table: [String: TOMLValue] = [:]
            while true {
                skipInlineWhitespace()
                if peek() == "}" { _ = advance(); break }
                var path: [String] = []
                repeat {
                    skipInlineWhitespace()
                    path.append(try parseKeyComponent())
                    skipInlineWhitespace()
                    if peek() == "." { _ = advance() } else { break }
                } while true
                try expect("=")
                skipInlineWhitespace()
                let value = try parseValue()
                Parser.insert(value, at: path, into: &table)
                skipInlineWhitespace()
                if peek() == "," {
                    _ = advance()
                } else if peek() == "}" {
                    _ = advance(); break
                } else {
                    throw TOMLError(message: "expected , or } in inline table", line: line)
                }
            }
            return .table(table)
        }

        mutating func parseScalar() throws -> TOMLValue {
            var token = ""
            while let scalar = peek(), scalar != "\n", scalar != "\r", scalar != ",",
                  scalar != "]", scalar != "}", scalar != "#" {
                token.unicodeScalars.append(scalar)
                _ = advance()
            }
            let trimmed = token.trimmingCharacters(in: .whitespaces)
            switch trimmed {
            case "true": return .boolean(true)
            case "false": return .boolean(false)
            default: break
            }
            let cleaned = trimmed.replacingOccurrences(of: "_", with: "")
            if let value = Int(cleaned) { return .integer(value) }
            if let value = Double(cleaned) { return .double(value) }
            guard !trimmed.isEmpty else {
                throw TOMLError(message: "expected a value", line: line)
            }
            // Dates and anything else exotic survive as text rather than failing the whole file.
            return .string(trimmed)
        }

        // MARK: - Insertion

        func valueAt(_ path: [String]) -> TOMLValue? {
            var current: TOMLValue = .table(root)
            for component in path {
                guard let table = current.tableValue, let next = table[component] else { return nil }
                current = next
            }
            return current
        }

        mutating func insert(_ value: TOMLValue, at path: [String]) {
            Parser.insert(value, at: path, into: &root)
        }

        /// Appends an empty table to the array at `path`, creating the array when needed, and
        /// points `currentPath` at it by index.
        mutating func appendTable(at path: [String]) {
            var existing = valueAt(path)?.arrayValue ?? []
            existing.append(.table([:]))
            Parser.insert(.array(existing), at: path, into: &root)
            currentPath = path + ["\(existing.count - 1)"]
        }

        static func insert(_ value: TOMLValue, at path: [String], into table: inout [String: TOMLValue]) {
            guard let head = path.first else { return }
            if path.count == 1 {
                if case .table(let incoming) = value,
                   case .table(let present)? = table[head], !incoming.isEmpty || present.isEmpty {
                    var merged = present
                    for (key, sub) in incoming { merged[key] = sub }
                    table[head] = .table(merged)
                } else if case .table = value, case .table? = table[head] {
                    // Re-entering an existing table header leaves it alone.
                } else {
                    table[head] = value
                }
                return
            }

            // An array-of-tables index is addressed by its numeric component.
            if let index = Int(path[1]), case .array(var elements)? = table[head], index < elements.count {
                var element = elements[index].tableValue ?? [:]
                insert(value, at: Array(path.dropFirst(2)), into: &element)
                elements[index] = .table(element)
                table[head] = .array(elements)
                return
            }

            var child = table[head]?.tableValue ?? [:]
            insert(value, at: Array(path.dropFirst()), into: &child)
            table[head] = .table(child)
        }
    }
}
