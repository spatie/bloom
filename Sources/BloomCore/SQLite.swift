import Foundation
import SQLite3
import Synchronization

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

extension SQLValue {
    /// Binds a typed identifier without unwrapping it at the call site.
    ///
    /// A static method that shadows the `text` case, so every `.text(workspace.id)` in `Store`
    /// reads exactly as it did when ids were strings. The alternative was `.text(id.rawValue)`
    /// several hundred times, which is noise in front of the SQL that is the point of those
    /// lines, and one `.rawValue` forgotten is a compile error rather than a bug, so the
    /// unwrapping was never buying anything.
    public static func text(_ id: some Identifier) -> SQLValue { .text(id.rawValue) }

    /// The nullable columns: `workspaces.parent_workspace_id`, and the joins that may not be
    /// there. Nil binds as SQL NULL, which is what the column already holds.
    public static func text(_ id: (some Identifier)?) -> SQLValue {
        id.map { .text($0.rawValue) } ?? .null
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

    /// Who is told when a write commits. See `StoreObservation.swift`.
    let changes: StoreChangeHub

    /// The tables the statements since the last commit have written to.
    ///
    /// Per connection and not on the hub, which is shared: two connections on one file each have
    /// their own transaction, and one of them committing must not publish rows the other has
    /// begun but not committed. `Store` serialises every call in here already, so the lock is
    /// about being able to say that in the type system rather than about contention.
    private let uncommitted = Mutex<Set<StoreDomain>>([])

    public init(path: String) throws {
        // Before anything that can throw, because a stored property has to be there whether this
        // initialiser returns or not.
        self.changes = StoreChangeHub.shared(forPath: path)
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
        // Also what keeps the update hook honest, which is not why it is here but is worth knowing
        // before anybody turns it off: the hook's one documented blind spot is the truncate
        // optimisation, where `DELETE FROM t` with no `WHERE` drops the whole table without
        // visiting a row, and enforcing foreign keys defeats that optimisation.
        try execute("PRAGMA foreign_keys = ON;")
        installUpdateHook()
    }

    deinit {
        if let handle {
            // Before the close, so nothing can be handed a pointer to an object that is on its way
            // out. The hook's context is this object unretained, which is sound because the handle
            // it is attached to is closed here, inside `self`, while `self` is still alive.
            sqlite3_update_hook(handle, nil, nil)
            sqlite3_close_v2(handle)
        }
    }

    /// Emission lives here, below `Store`, and that is the point of the design rather than an
    /// implementation detail.
    ///
    /// Every write `Store` makes goes through `run`, `execute` or `transaction`, so the hook sees
    /// all of them whichever Swift method issued the SQL, including the ones written next year.
    /// A `Store` method added by somebody who has never read this file emits correctly, having
    /// done nothing at all, and there is no rule for a reviewer to remember or a linter to check.
    ///
    /// The hook fires for every row an `INSERT`, `UPDATE` or `DELETE` touches, from inside the
    /// statement, and cannot call back into SQLite. So it does the smallest possible thing: turn
    /// the table name into a domain and remember it. Publishing waits for the commit.
    private func installUpdateHook() {
        sqlite3_update_hook(
            handle,
            { context, _, _, table, _ in
                // Captures nothing, and cannot: a closure with a capture list will not convert to
                // a C function pointer at all. The context pointer is the only channel there is.
                guard let context, let table,
                      // Named tables only. `sqlite_sequence` and anything else SQLite keeps for
                      // itself is not a domain anybody subscribes to, and a table added to the
                      // schema without a case here is ignored rather than trapping in front of a
                      // user.
                      let domain = StoreDomain(rawValue: String(cString: table)) else { return }
                _ = Unmanaged<SQLiteDatabase>.fromOpaque(context)
                    .takeUnretainedValue()
                    .uncommitted.withLock { $0.insert(domain) }
            },
            // Unretained on purpose: a retained context would be a reference this object holds to
            // itself through SQLite, so it would never be deallocated and the file would never be
            // closed. Safe because the pointer is only ever dereferenced by a hook attached to a
            // handle that `deinit` detaches before it closes, above.
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    /// Publishes what the statement that just ran committed, and nothing when it did not.
    ///
    /// `sqlite3_get_autocommit` is the question being asked: it is false for exactly as long as an
    /// explicit transaction is open, so a statement inside one accumulates and says nothing, and
    /// the `COMMIT` going through `execute` is what lets the whole batch out as one. Publishing
    /// from inside the hook instead would announce every row of a transaction that is about to
    /// roll back, and `Store.appendNext` rolls back on purpose, up to sixteen times, whenever two
    /// writers collide on a sequence number.
    ///
    /// So `transaction` is the only thing allowed to issue a `ROLLBACK`, and it clears the pending
    /// set first. A bare `execute("ROLLBACK;")` anywhere else would publish the abandoned writes
    /// as though they had landed.
    private func flushChanges() {
        guard sqlite3_get_autocommit(handle) != 0 else { return }
        let domains = uncommitted.withLock { pending in
            defer { pending.removeAll(keepingCapacity: true) }
            return pending
        }
        changes.publish(domains)
    }

    private func fail(_ sql: String?) -> SQLiteError {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "database is closed"
        return SQLiteError(message: message, sql: sql)
    }

    public func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw fail(sql) }
        flushChanges()
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
        flushChanges()
        return sqlite3_last_insert_rowid(handle)
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            // Nothing inside published, because autocommit was off for all of it. This is the one
            // statement that lets the batch out, so a transaction is one change rather than one
            // per statement.
            try execute("COMMIT;")
            return result
        } catch {
            // Before the rollback, not after. Whatever the hook saw did not happen, and a
            // subscriber told about it would go and read rows that are not there.
            uncommitted.withLock { $0.removeAll(keepingCapacity: true) }
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public var userVersion: Int32 {
        get { (try? query("PRAGMA user_version;").first?.int("user_version")).flatMap { $0 }.map(Int32.init) ?? 0 }
        set { try? execute("PRAGMA user_version = \(newValue);") }
    }
}
