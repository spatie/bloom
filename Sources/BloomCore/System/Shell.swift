import Foundation
import Synchronization

/// Result of a finished subprocess.
public struct ShellResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public var ok: Bool { status == 0 }

    /// stdout with trailing newlines removed, the form almost every caller wants.
    public var trimmed: String {
        stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var lines: [String] {
        trimmed.isEmpty ? [] : trimmed.components(separatedBy: "\n")
    }
}

public struct ShellError: Error, CustomStringConvertible {
    public let command: String
    public let status: Int32
    public let stderr: String

    public var description: String {
        "`\(command)` exited \(status): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

/// Every subprocess in Bloom goes through here.
///
/// Nothing uses a login shell: commands are exec'd directly so an argument containing a space
/// or a quote can never be reinterpreted. `Shell.script` is the deliberate exception, used for
/// user-authored setup and run scripts.
public enum Shell {
    /// Directories added to PATH for spawned processes, because GUI apps launched from Finder
    /// inherit a minimal PATH that lacks Homebrew, mise, fnm, and friends.
    public static let extraPaths = ExecutableSearchPath.additionalDirectories()

    /// How many subprocesses this process has started since launch.
    ///
    /// Here rather than in a probe because the number cannot be taken from outside. Polling `ps`
    /// at 20Hz for a minute against the running app saw nine children where the diff stat loop
    /// alone starts several a second: a `git rev-parse` lives for about ten milliseconds, so a
    /// sampler misses almost all of them and reports a number that looks reassuring and is wrong.
    /// A counter incremented where the process is actually started cannot miss one.
    ///
    /// Relaxed ordering, because a count is read after the work it counts has finished and nothing
    /// is synchronised against it.
    private static let spawns = Atomic<Int>(0)

    /// Called by the captured-process worker and other process launchers. Git's raw and text
    /// reads share that worker, so both contribute exactly once.
    static func countSpawn() {
        spawns.add(1, ordering: .relaxed)
    }

    /// The running total, for the probes. See `IdleProbe`.
    public static var spawnCount: Int {
        spawns.load(ordering: .relaxed)
    }

    /// This process's environment with the PATH above merged in, worked out once.
    ///
    /// It used to be rebuilt per spawn: the whole process environment copied, PATH split, about 45
    /// entries deduped through a `Set`, and `which` asks for it before every subprocess as well.
    /// Nothing in Bloom calls `setenv`, so the base cannot move under this, and the two callers
    /// that pass an overlay get a copy-on-write copy of it rather than a rebuild.
    private static let base: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        let existing = env["PATH"]?.components(separatedBy: ":") ?? []
        var seen = Set<String>()
        let merged = (existing + extraPaths).filter { seen.insert($0).inserted }
        env["PATH"] = merged.joined(separator: ":")
        return env
    }()

    public static func environment(extra: [String: String] = [:]) -> [String: String] {
        guard !extra.isEmpty else { return base }
        var env = base
        for (key, value) in extra { env[key] = value }
        return env
    }

    /// Where a name was last found, so a lookup is one `stat` rather than a walk of the whole PATH.
    ///
    /// `Mutex` rather than `nonisolated(unsafe)`, for the reason given on `EventFanout` in
    /// `SessionRunner`: this is read from every actor in the app and from the drain threads.
    private static let found = Mutex<[String: String]>([:])

    /// Resolve an executable name to an absolute path using the merged PATH.
    ///
    /// **Every subprocess in Bloom starts with one of these, and the walk is not cheap.** It
    /// rebuilds the merged environment, splits PATH and stats a candidate per entry, 37 of them on
    /// the owner's machine. `TerminalPersistence.tmuxPath` had already resolved that by hand for
    /// one binary; the six-second diff poll runs four git calls per workspace and pays for it
    /// afresh every time, which is a hundred and fifty stats per workspace per pass for an answer
    /// that has not moved since launch.
    ///
    /// **Only a hit is remembered, and it is checked before it is handed back.** A miss must not
    /// be, because "not installed" is the one answer that legitimately changes while the app is
    /// running: `GitHubAvailability` re-asks precisely so that signing in to `gh` from a terminal
    /// is noticed, and `WorkspaceNamer.isAvailable` is asked afresh on every create for the same
    /// reason. Remembering a miss would make installing a CLI something you have to relaunch
    /// Bloom to be told about. The one `isExecutableFile` on the remembered path is what makes the
    /// other direction safe: a binary that has been moved or uninstalled falls through to the full
    /// walk rather than being reported at a path that is no longer there.
    public static func which(_ name: String) -> String? {
        if name.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        if let remembered = found.withLock({ $0[name] }),
           FileManager.default.isExecutableFile(atPath: remembered) {
            return remembered
        }
        for dir in environment()["PATH"]?.components(separatedBy: ":") ?? [] {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                found.withLock { $0[name] = candidate }
                return candidate
            }
        }
        // Nothing to unremember: a name only enters the table when it was found, and a stale entry
        // has already been rejected by the check above.
        return nil
    }

    @discardableResult
    public static func run(
        _ executable: String,
        _ arguments: [String] = [],
        cwd: String? = nil,
        env: [String: String] = [:],
        stdin: String? = nil,
        timeout: Duration? = nil,
        outputLimit: Int = 64 * 1_024 * 1_024
    ) async throws -> ShellResult {
        let result = try await runBytes(
            executable, arguments, cwd: cwd, env: env,
            stdin: stdin.map { Data($0.utf8) }, timeout: timeout, outputLimit: outputLimit
        )
        return ShellResult(
            status: result.status,
            stdout: String(decoding: result.stdout, as: UTF8.self),
            stderr: String(decoding: result.stderr, as: UTF8.self)
        )
    }

    /// Limits fail explicitly, so a partial status or patch can never masquerade as complete.
    public static func runBytes(
        _ executable: String,
        _ arguments: [String] = [],
        cwd: String? = nil,
        env: [String: String] = [:],
        stdin: Data? = nil,
        timeout: Duration? = nil,
        outputLimit: Int = 64 * 1_024 * 1_024
    ) async throws -> ShellBytes {
        try Task.checkCancellation()
        guard let path = which(executable) else {
            throw ShellError(command: executable, status: 127, stderr: "\(executable) not found on PATH")
        }
        return try await CapturedProcess(
            executable: path, arguments: arguments, cwd: cwd, environment: environment(extra: env),
            input: stdin, timeout: timeout, outputLimit: outputLimit
        ).run()
    }

    /// Run and throw unless the exit status is zero.
    @discardableResult
    public static func check(
        _ executable: String,
        _ arguments: [String] = [],
        cwd: String? = nil,
        env: [String: String] = [:],
        timeout: Duration? = nil
    ) async throws -> ShellResult {
        let result = try await run(executable, arguments, cwd: cwd, env: env, timeout: timeout)
        guard result.ok else {
            throw ShellError(
                command: ([executable] + arguments).joined(separator: " "),
                status: result.status,
                stderr: result.stderr.isEmpty ? result.stdout : result.stderr
            )
        }
        return result
    }

    /// Run a user-authored script through the platform shell. Used for setup and run scripts, where the
    /// whole point is that the user wrote shell.
    @discardableResult
    public static func script(
        _ source: String,
        cwd: String,
        env: [String: String] = [:],
        timeout: Duration? = nil
    ) async throws -> ShellResult {
        try await run(LoginShell.fallback, ["-c", source], cwd: cwd, env: env, timeout: timeout)
    }
}
