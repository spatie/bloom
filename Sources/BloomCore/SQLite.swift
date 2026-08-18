import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLValue: Sendable, Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    public var intValue: Int64? {
        switch self {
        case .int(let value): value
        case .double(let value): Int64(value)
        case .text(let value): Int64(value)
        default: nil
        }
    }

    public var stringValue: String? {
        switch self {
        case .text(let value): value
        case .int(let value): String(value)
        case .double(let value): String(value)
        default: nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let value): value
        case .int(let value): Double(value)
        case .text(let value): Double(value)
        default: nil
        }
    }

    public var dataValue: Data? {
        switch self {
        case .blob(let value): value
        case .text(let value): Data(value.utf8)
        default: nil
        }
    }
}

public struct Row: Sendable {
    public let columns: [String: SQLValue]

    public subscript(key: String) -> SQLValue { columns[key] ?? .null }

    public func int(_ key: String) -> Int64? { self[key].intValue }
    public func string(_ key: String) -> String? { self[key].stringValue }
    public func double(_ key: String) -> Double? { self[key].doubleValue }
    public func data(_ key: String) -> Data? { self[key].dataValue }

    public func bool(_ key: String) -> Bool { (self[key].intValue ?? 0) != 0 }

    public func date(_ key: String) -> Date? {
        guard let seconds = self[key].doubleValue else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

public struct SQLiteError: Error, CustomStringConvertible {
    public let message: String
    public let sql: String?

    public var description: String {
        if let sql { return "\(message) [\(sql.prefix(200))]" }
        return message
    }
}

/// A very small synchronous SQLite wrapper. Access is serialised by `Store`, which is an actor,
/// so this type itself does no locking beyond SQLite's own.
public final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?

    public init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open \(path)"
            sqlite3_close_v2(handle)
            throw SQLiteError(message: message, sql: nil)
        }
        self.handle = handle
        sqlite3_busy_timeout(handle, 5_000)
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA synchronous = NORMAL;")
        try execute("PRAGMA foreign_keys = ON;")
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    private func fail(_ sql: String?) -> SQLiteError {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "database is closed"
        return SQLiteError(message: message, sql: sql)
    }

    public func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw fail(sql) }
    }

    private func prepare(_ sql: String, _ bindings: [SQLValue]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw fail(sql)
        }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32 = switch value {
            case .null: sqlite3_bind_null(statement, index)
            case .int(let v): sqlite3_bind_int64(statement, index, v)
            case .double(let v): sqlite3_bind_double(statement, index, v)
            case .text(let v): sqlite3_bind_text(statement, index, v, -1, sqliteTransient)
            case .blob(let v): v.withUnsafeBytes {
                sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(v.count), sqliteTransient)
            }
            }
            guard status == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw fail(sql)
            }
        }
        return statement
    }

    private func value(of statement: OpaquePointer, at index: Int32) -> SQLValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER: .int(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT: .double(sqlite3_column_double(statement, index))
        case SQLITE_TEXT: .text(String(cString: sqlite3_column_text(statement, index)))
        case SQLITE_BLOB:
            if let bytes = sqlite3_column_blob(statement, index) {
                .blob(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index))))
            } else {
                .null
            }
        default: .null
        }
    }

    @discardableResult
    public func query(_ sql: String, _ bindings: [SQLValue] = []) throws -> [Row] {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }

        let columnCount = sqlite3_column_count(statement)
        var names: [String] = []
        names.reserveCapacity(Int(columnCount))
        for index in 0..<columnCount {
            names.append(String(cString: sqlite3_column_name(statement, index)))
        }

        var rows: [Row] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw fail(sql) }
            var columns: [String: SQLValue] = [:]
            columns.reserveCapacity(Int(columnCount))
            for index in 0..<columnCount {
                columns[names[Int(index)]] = value(of: statement, at: index)
            }
            rows.append(Row(columns: columns))
        }
        return rows
    }

    @discardableResult
    public func run(_ sql: String, _ bindings: [SQLValue] = []) throws -> Int64 {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        guard step == SQLITE_DONE || step == SQLITE_ROW else { throw fail(sql) }
        return sqlite3_last_insert_rowid(handle)
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public var userVersion: Int32 {
        get { (try? query("PRAGMA user_version;").first?.int("user_version")).flatMap { $0 }.map(Int32.init) ?? 0 }
        set { try? execute("PRAGMA user_version = \(newValue);") }
    }
}
