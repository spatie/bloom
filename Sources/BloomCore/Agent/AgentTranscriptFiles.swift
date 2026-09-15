import Foundation

/// One conversation an agent CLI kept on disk for a Bloom chat: which CLI, and its own id for it.
public struct AgentThread: Sendable, Hashable {
    public var kind: AgentKind
    public var agentSessionID: String

    public init(kind: AgentKind, agentSessionID: String) {
        self.kind = kind
        self.agentSessionID = agentSessionID
    }
}

/// The transcripts an agent CLI wrote for one worktree, found so a permanent delete can take them.
///
/// **Why this exists.** Deleting an archived workspace removed every row Bloom held and left the
/// CLI's own copy of the same conversation behind: Claude Code keeps every session as a JSONL file
/// under `~/.claude/projects/`, Codex keeps a rollout file per thread under `~/.codex/sessions/`,
/// and on a server that runs agents all day those two directories outgrow the database. A delete
/// that promises "nothing anywhere else holds a copy" and leaves both is not the delete it says.
///
/// **Only paths derived from this worktree, never a glob.** Two rules decide, and both are
/// measured against files on this Mac rather than assumed:
///
/// - Claude Code names a project directory after the working directory with every character that
///   is not an ASCII letter or digit replaced by a dash. `/private/tmp/claude-501/-Users-freek`
///   is `-private-tmp-claude-501--Users-freek`, the doubled dash being the slash and the dash that
///   were both there. Two different paths can share a name (`/a.b` and `/a-b`), so the name only
///   says where to look. A file is taken when the `cwd` its own lines record is this worktree, or
///   when it is one of this workspace's own sessions by id and records no other directory. A file
///   that records another `cwd` stays, and the directory only goes once nothing is left in it.
/// - Codex is found by thread id, which Bloom stored on the chat, in a file named
///   `rollout-<time>-<thread id>.jsonl`. The file's first line is `session_meta`, and it is taken
///   only when that line names the same thread and this worktree as its `cwd`.
///
/// **A thread another workspace still uses is never taken.** `ArchivedCarryOn` resumes an
/// archived chat's Claude session from a new worktree, and Claude Code goes on appending to the
/// file in the archived worktree's project directory. Deleting the archived record must not delete
/// the conversation the live workspace is resuming, so `keeping` names every thread id a surviving
/// chat holds and none of them is touched.
///
/// Claude Code shortens a name longer than 200 characters and adds a hash whose recipe is not
/// written down anywhere this project can check, so a worktree path that long is left alone
/// rather than guessed at.
public struct AgentTranscriptFiles: Sendable, Equatable {
    /// Files and directories to remove, absolute, sorted so two plans compare equal.
    public private(set) var paths: [String]
    public private(set) var bytes: Int
    public private(set) var claudeSessions: Int
    public private(set) var codexSessions: Int

    public init(paths: [String] = [], bytes: Int = 0, claudeSessions: Int = 0, codexSessions: Int = 0) {
        self.paths = paths
        self.bytes = bytes
        self.claudeSessions = claudeSessions
        self.codexSessions = codexSessions
    }

    public var isEmpty: Bool { paths.isEmpty }

    /// Longest name Claude Code writes without shortening it.
    static let longestClaudeName = 200
    /// How much of a transcript is read looking for its `cwd`. A Claude session's first lines are
    /// queue bookkeeping and the first `cwd` measured here was 4,427 bytes in; a Codex
    /// `session_meta` line carries the base instructions and runs to tens of kilobytes.
    static let headBytes = 1_048_576

    /// The directory name Claude Code gives a working directory, or nil when it would be shortened.
    public static func claudeProjectDirectoryName(forWorktree path: String) -> String? {
        // Per UTF-16 unit, because Claude Code's own rule is a JavaScript regular expression over
        // a JavaScript string: a character outside the Basic Multilingual Plane is two dashes.
        let name = String(path.utf16.map { unit -> Character in
            switch unit {
            case 48...57, 65...90, 97...122: Character(UnicodeScalar(UInt8(unit)))
            default: "-"
            }
        })
        return name.count > longestClaudeName ? nil : name
    }

    /// Finds what the CLIs kept for `worktree`. Reads the filesystem and runs nothing.
    ///
    /// - Parameter threads: every agent thread this workspace's chats held, closed chats included.
    /// - Parameter keeping: thread ids a chat outside what is being deleted still holds.
    /// - Parameter codexHome: `CODEX_HOME` when it is set, since Codex writes there instead.
    public static func find(
        worktree: String, threads: [AgentThread], keeping: Set<String>, home: String, codexHome: String? = nil
    ) -> AgentTranscriptFiles {
        guard worktree.hasPrefix("/"), worktree.count > 1 else { return AgentTranscriptFiles() }
        var plan = AgentTranscriptFiles()
        let claudeIDs = Set(threads.filter { $0.kind == .claudeCode }.map(\.agentSessionID)).subtracting(keeping)
        plan.addClaude(worktree: worktree, sessionIDs: claudeIDs, keeping: keeping, home: home)
        let codexIDs = threads.filter { $0.kind == .codex && !keeping.contains($0.agentSessionID) && isSafeThreadID($0.agentSessionID) }.map(\.agentSessionID)
        plan.addCodex(worktree: worktree, threadIDs: Set(codexIDs), root: codexHome ?? (home as NSString).appendingPathComponent(".codex"))
        plan.paths.sort()
        return plan
    }

    /// Removes every planned path, and names the ones that would not go.
    public func remove() -> [String] {
        paths.compactMap { path in
            do {
                try FileManager.default.removeItem(atPath: path)
                return nil
            } catch {
                return FileManager.default.fileExists(atPath: path) ? path : nil
            }
        }
    }

    /// The line a confirmation lists, or nil when the CLIs kept nothing for this worktree.
    public var loss: String? {
        guard !isEmpty else { return nil }
        var kinds: [String] = []
        if claudeSessions > 0 { kinds.append(Counted.of(claudeSessions, "Claude Code session")) }
        if codexSessions > 0 { kinds.append(Counted.of(codexSessions, "Codex session")) }
        return kinds.joined(separator: " and ") + " kept by the agent CLIs, holding \(bytes.formatted(.byteCount(style: .file)))"
    }

    // MARK: - Claude Code

    private mutating func addClaude(worktree: String, sessionIDs: Set<String>, keeping: Set<String>, home: String) {
        guard let name = Self.claudeProjectDirectoryName(forWorktree: worktree) else { return }
        let directory = ((home as NSString).appendingPathComponent(".claude/projects") as NSString).appendingPathComponent(name)
        guard Self.isRealDirectory(directory),
              let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        var taken: Set<String> = []
        var sessions = 0
        for entry in entries where entry.hasSuffix(".jsonl") {
            let stem = String(entry.dropLast(".jsonl".count))
            guard !keeping.contains(stem) else { continue }
            let file = (directory as NSString).appendingPathComponent(entry)
            let recorded = Self.recordedDirectory(in: file)
            let belongs: Bool
            if let recorded {
                belongs = recorded == worktree || recorded.hasPrefix(worktree + "/")
            } else {
                belongs = sessionIDs.contains(stem)
            }
            guard belongs else { continue }
            taken.insert(entry)
            sessions += 1
            // A session's subagent transcripts and tool output live in a directory named after it.
            if entries.contains(stem) { taken.insert(stem) }
        }
        guard sessions > 0 else { return }
        claudeSessions += sessions
        if taken.count == entries.count {
            paths.append(directory)
            bytes += Self.size(of: directory)
        } else {
            for entry in taken {
                let path = (directory as NSString).appendingPathComponent(entry)
                paths.append(path)
                bytes += Self.size(of: path)
            }
        }
    }

    // MARK: - Codex

    private mutating func addCodex(worktree: String, threadIDs: Set<String>, root: String) {
        guard !threadIDs.isEmpty else { return }
        for folder in ["sessions", "archived_sessions"] {
            let base = (root as NSString).appendingPathComponent(folder)
            // By relative path joined back onto `base`, not by URL: on macOS the URL enumerator
            // hands back `/private/var/...` for a base spelt `/var/...`, and a plan whose paths
            // are spelt differently from the directory it was asked about compares unequal. This
            // walk does not follow symbolic links, and a link is refused as a file below.
            guard Self.isRealDirectory(base), let walker = FileManager.default.enumerator(atPath: base) else { continue }
            while let relative = walker.nextObject() as? String {
                let name = (relative as NSString).lastPathComponent
                guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl"),
                      walker.fileAttributes?[.type] as? FileAttributeType == .typeRegular,
                      let id = threadIDs.first(where: { name.hasSuffix("-\($0).jsonl") }) else { continue }
                let path = (base as NSString).appendingPathComponent(relative)
                guard Self.codexMeta(in: path, matches: id, worktree: worktree) else { continue }
                paths.append(path)
                bytes += Self.size(of: path)
                codexSessions += 1
            }
        }
    }

    /// A thread id is spliced into a file name comparison, so anything that could reach outside a
    /// name is refused before it gets there.
    static func isSafeThreadID(_ id: String) -> Bool {
        (8...128).contains(id.count) && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
            && id.allSatisfy(\.isASCII)
    }

    private static func codexMeta(in path: String, matches id: String, worktree: String) -> Bool {
        guard let line = head(of: path).split(separator: UInt8(ascii: "\n"), maxSplits: 1).first,
              let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any] else { return false }
        let named = payload["id"] as? String == id || payload["session_id"] as? String == id
        return named && payload["cwd"] as? String == worktree
    }

    // MARK: - Reading

    /// The first `cwd` any line of a transcript records, within the head that is read.
    private static func recordedDirectory(in path: String) -> String? {
        for line in head(of: path).split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let cwd = object["cwd"] as? String, !cwd.isEmpty else { continue }
            return cwd
        }
        return nil
    }

    private static func head(of path: String) -> Data {
        guard let handle = FileHandle(forReadingAtPath: path) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: headBytes)) ?? Data()
    }

    /// A directory that is not a symbolic link, so a link planted in either tree cannot send a
    /// delete somewhere else.
    private static func isRealDirectory(_ path: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return false }
        return attributes[.type] as? FileAttributeType == .typeDirectory
    }

    static func size(of path: String) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return 0 }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            return (attributes[.size] as? NSNumber)?.intValue ?? 0
        }
        guard let walker = FileManager.default.enumerator(atPath: path) else { return 0 }
        var total = 0
        while walker.nextObject() != nil {
            if walker.fileAttributes?[.type] as? FileAttributeType == .typeRegular {
                total += (walker.fileAttributes?[.size] as? NSNumber)?.intValue ?? 0
            }
        }
        return total
    }
}
