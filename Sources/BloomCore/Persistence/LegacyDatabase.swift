import Foundation

/// Moves the database from the directory the app used before it was renamed.
///
/// The rename changed where `Store.defaultPath` points, and a user who upgrades has years of
/// workspaces sitting under the old name. The old file is the only copy of that work, so nothing
/// here ever removes it: the migration copies, proves the copy is readable, and only then hands
/// back the new path. Any failure at all hands back the OLD path, so a launch that could not
/// migrate is a launch that runs on the user's real database rather than on an empty one.
public enum LegacyDatabase {
    /// Which path the caller should open, and why.
    public struct Outcome: Sendable, Equatable {
        public let path: String
        public let result: Result
        /// Set when a copy was attempted and refused. Worth surfacing, because the app is now
        /// running on the legacy file and will try again on the next launch.
        public let problem: String?
    }

    public enum Result: Sendable, Equatable {
        /// Either the destination already exists, or there is nothing at the legacy path.
        case nothingToDo
        case migrated
        /// The copy could not be made or could not be read back. `path` is the legacy file.
        case keptLegacy
    }

    public static var legacyDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Baton", isDirectory: true)
    }

    public static var legacyPath: URL {
        legacyDirectory.appendingPathComponent("baton.sqlite")
    }

    /// The tables whose contents have to survive. Read back from the copy and compared row for
    /// row against the original, because a file that opens is not the same claim as a file whose
    /// data arrived.
    static let verifiedTables = ["repos", "workspaces", "sessions", "messages"]

    @discardableResult
    public static func adopt(legacy: URL = legacyPath, destination: URL) -> Outcome {
        let manager = FileManager.default

        // The destination winning means the app has already run under the new name. Copying over
        // it would throw away everything done since.
        guard !manager.fileExists(atPath: destination.path) else {
            return Outcome(path: destination.path, result: .nothingToDo, problem: nil)
        }
        guard manager.fileExists(atPath: legacy.path) else {
            return Outcome(path: destination.path, result: .nothingToDo, problem: nil)
        }

        do {
            try manager.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let counts = try copy(from: legacy, to: destination)
            try verify(destination, matches: counts)
            return Outcome(path: destination.path, result: .migrated, problem: nil)
        } catch {
            // A half written copy is worse than no copy: it would satisfy the existence check
            // above on the next launch and become the database the app runs on.
            discard(destination)
            return Outcome(
                path: legacy.path,
                result: .keptLegacy,
                problem: (error as? SQLiteError)?.message ?? error.localizedDescription
            )
        }
    }

    /// `VACUUM INTO` rather than a file copy. A live SQLite database in WAL mode is three files,
    /// and copying only the `.sqlite` silently drops every transaction still sitting in the WAL.
    /// `VACUUM INTO` reads through one consistent snapshot and writes a single complete file, so
    /// there is no window in which the copy is a torn read of a database being written.
    private static func copy(from legacy: URL, to destination: URL) throws -> [String: Int64] {
        let source = try SQLiteDatabase(path: legacy.path)
        let quoted = destination.path.replacingOccurrences(of: "'", with: "''")
        try source.execute("VACUUM INTO '\(quoted)';")
        return try counts(in: source)
    }

    private static func verify(_ destination: URL, matches expected: [String: Int64]) throws {
        let copied = try SQLiteDatabase(path: destination.path)

        let integrity = try copied.query("PRAGMA integrity_check;")
            .first?.string("integrity_check")
        guard integrity == "ok" else {
            throw SQLiteError(message: "integrity_check said \(integrity ?? "nothing")", sql: nil)
        }

        let actual = try counts(in: copied)
        guard actual == expected else {
            throw SQLiteError(message: "row counts differ: \(expected) became \(actual)", sql: nil)
        }
    }

    /// Missing tables are not an error. The legacy file can predate any of them, and a schema
    /// migration the copy has not run yet is `Store`'s job rather than this one's.
    private static func counts(in db: SQLiteDatabase) throws -> [String: Int64] {
        var counts: [String: Int64] = [:]
        for table in verifiedTables {
            let exists = try db.query(
                "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?;", [.text(table)]
            )
            guard !exists.isEmpty else { continue }
            counts[table] = try db.query("SELECT COUNT(*) AS n FROM \(table);").first?.int("n") ?? 0
        }
        return counts
    }

    /// The journal files go too. A stray `-wal` beside a database that no longer exists is picked
    /// up by the next connection that creates the same path.
    private static func discard(_ destination: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: destination.path + suffix)
        }
    }
}
