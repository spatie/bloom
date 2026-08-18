import Foundation

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

/// Every subprocess in Baton goes through here.
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

    public static func environment(extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let existing = env["PATH"]?.components(separatedBy: ":") ?? []
        var seen = Set<String>()
        let merged = (existing + extraPaths).filter { seen.insert($0).inserted }
        env["PATH"] = merged.joined(separator: ":")
        for (key, value) in extra { env[key] = value }
        return env
    }

    /// Resolve an executable name to an absolute path using the merged PATH.
    public static func which(_ name: String) -> String? {
        if name.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        for dir in environment()["PATH"]?.components(separatedBy: ":") ?? [] {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
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

        let collector = OutputCollector()

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                collector.appendOut(data)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                collector.appendErr(data)
            }
        }

        try process.run()

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
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                process.terminationHandler = { _ in continuation.resume() }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        timeoutTask?.cancel()

        // Drain anything the readability handlers have not picked up yet.
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? outPipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
            collector.appendOut(rest)
        }
        if let rest = try? errPipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
            collector.appendErr(rest)
        }

        return ShellResult(
            status: process.terminationStatus,
            stdout: collector.stdoutString,
            stderr: collector.stderrString
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

/// Thread-safe accumulator for the two output streams.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func appendOut(_ data: Data) {
        lock.lock(); out.append(data); lock.unlock()
    }

    func appendErr(_ data: Data) {
        lock.lock(); err.append(data); lock.unlock()
    }

    var stdoutString: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: out, as: UTF8.self)
    }

    var stderrString: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: err, as: UTF8.self)
    }
}
