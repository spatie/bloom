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
    public static let extraPaths: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            "\(home)/.local/bin",
            // Node installs put binaries wherever the user's package manager decided. `codex`
            // lives in .npm-packages/bin on this machine, and a Finder launch would otherwise
            // report it as not installed while a terminal launch found it.
            "\(home)/.npm-packages/bin",
            "\(home)/.volta/bin",
            "\(home)/.yarn/bin",
            "\(home)/.bun/bin",
            "\(home)/.cargo/bin",
            "\(home)/.composer/vendor/bin",
            "\(home)/bin",
        ]
    }()

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

    /// Called by every site that starts a process. `Git.runRaw` has its own `Process` for the
    /// byte-preserving parsers, so it calls this too, and a new spawn site that forgets to is a
    /// probe that quietly under-reports.
    static func countSpawn() {
        spawns.add(1, ordering: .relaxed)
    }

    /// The running total, for the probes. See `IdleProbe`.
    public static var spawnCount: Int {
        spawns.load(ordering: .relaxed)
    }

    public static func environment(extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let existing = env["PATH"]?.components(separatedBy: ":") ?? []
        var seen = Set<String>()
        let merged = (existing + extraPaths).filter { seen.insert($0).inserted }
        env["PATH"] = merged.joined(separator: ":")
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
        timeout: Duration? = nil
    ) async throws -> ShellResult {
        // Spawning a process the caller has already given up on is pure cost: the cancellation
        // handler below would fork it and SIGTERM it in the same breath. The refresh loop's five
        // second deadline cancels a whole queue of these at once.
        try Task.checkCancellation()

        guard let path = which(executable) else {
            throw ShellError(command: executable, status: 127, stderr: "\(executable) not found on PATH")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment(extra: env)
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let inPipe: Pipe? = stdin == nil ? nil : Pipe()
        if let inPipe { process.standardInput = inPipe }

        let collector = PipeCollector()

        // Read each pipe to EOF on its own thread rather than through `readabilityHandler`.
        //
        // The handler approach has a race that loses output: clearing the handler after the
        // process exits can discard whatever the dispatch source had already buffered, and
        // draining with `readToEnd` afterwards then returns nothing. It is rare and load
        // dependent, which is the worst kind: under a parallel test run it turned up as an empty
        // `git diff`, and in the app it would have been an empty diff shown as though the file
        // had not changed. Reading to EOF cannot lose anything, and EOF is also the signal that
        // the child is done writing.
        let outReader = Thread {
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            collector.appendOut(data)
            collector.finishOut()
        }
        let errReader = Thread {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            collector.appendErr(data)
            collector.finishErr()
        }
        outReader.stackSize = 512 * 1_024
        errReader.stackSize = 512 * 1_024

        // Installed before `run()`, never after. See `ProcessExitGate`: a child that exits before
        // the handler exists never calls it, and the wait below would never end.
        let exit = ProcessExitGate()
        process.terminationHandler = { _ in exit.signal() }

        try process.run()
        Shell.countSpawn()

        outReader.start()
        errReader.start()

        if let inPipe, let stdin {
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
        }

        let timeoutTask: Task<Void, Never>? = timeout.map { duration in
            Task {
                try? await Task.sleep(for: duration)
                if process.isRunning { process.terminate() }
            }
        }

        await withTaskCancellationHandler {
            await exit.wait()
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        timeoutTask?.cancel()

        // The child has exited, but its output is only complete once both pipes have reached EOF.
        // Returning before that is exactly how output goes missing.
        await collector.waitForEOF()

        return ShellResult(
            status: process.terminationStatus,
            stdout: String(decoding: collector.out, as: UTF8.self),
            stderr: String(decoding: collector.err, as: UTF8.self)
        )
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

    /// Run a user-authored script through zsh. Used only for setup and run scripts, where the
    /// whole point is that the user wrote shell.
    @discardableResult
    public static func script(
        _ source: String,
        cwd: String,
        env: [String: String] = [:],
        timeout: Duration? = nil
    ) async throws -> ShellResult {
        try await run("/bin/zsh", ["-c", source], cwd: cwd, env: env, timeout: timeout)
    }
}

/// Thread-safe accumulator for a subprocess's two output streams, and the gate that says both are
/// complete. `Shell.run` and `Git.runRaw` share it, because it was two identical classes whose
/// only difference was whether the caller decoded stdout afterwards.
///
/// The two buffers share one `Mutex` because they are two halves of one result, read together
/// once both streams have finished. `Mutex<State>` rather than `NSLock` plus
/// `@unchecked Sendable`, for the reason given on `EventFanout` in `SessionRunner`.
final class PipeCollector: Sendable {
    private struct State {
        var out = Data()
        var err = Data()
    }

    private let state = Mutex(State())
    /// One count per stream. Waiting on both is what guarantees nothing is still in flight.
    private let eof = DispatchGroup()

    init() {
        eof.enter()
        eof.enter()
    }

    func appendOut(_ data: Data) {
        state.withLock { $0.out.append(data) }
    }

    func appendErr(_ data: Data) {
        state.withLock { $0.err.append(data) }
    }

    func finishOut() { eof.leave() }
    func finishErr() { eof.leave() }

    func waitForEOF() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            eof.notify(queue: .global()) { continuation.resume() }
        }
    }

    /// Bytes, undecoded, because git's `-z` output is byte strings that a `String` round trip
    /// would silently rewrite. `Shell.run` decodes at the call site instead.
    var out: Data { state.withLock(\.out) }

    var err: Data { state.withLock(\.err) }
}
