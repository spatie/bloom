import Foundation

/// The Python file Bloom puts on a server, and everything about keeping it current.
///
/// **How it is versioned: the file says so, in one literal, and that literal is the only thing
/// compared.** `bloomd version` prints it, `Bloomd.version(of:)` reads it out of the copy inside
/// the app bundle, and an install happens whenever the two strings differ. Not a hash of the file,
/// because reformatting a comment would then reinstall on every server the user has; not a
/// modification date, because a file copied by `rsync` or restored from a backup carries somebody
/// else's; not "newer than", because a version is a string and Bloom only ever ships forward, so
/// "different" is the whole of the question. Bumping the literal in `Resources/bloomd.py` is what
/// deploys it, and there is nothing else to remember.
public enum Bloomd {
    /// Where it goes on the server, relative to that user's home.
    ///
    /// Under the home directory rather than `/usr/local/bin`, because installing there needs
    /// `sudo` and Bloom has no business asking for it: everything here runs as the user whose SSH
    /// key opened the connection, and a per-user install is the honest scope for a per-user tool.
    /// The directory does not exist on a fresh server, which is why `install` creates it.
    public static let relativePath = ".bloom/bin/bloomd"

    /// The absolute path on a server whose home directory is `home`.
    ///
    /// An absolute path rather than `~/...` because the path is quoted for the remote shell, and
    /// quoting is exactly what stops `~` expanding. The home directory is a fact the probe already
    /// brought back, so there is nothing to guess.
    public static func path(inHome home: String) -> String {
        (home as NSString).appendingPathComponent(relativePath)
    }

    /// The version literal at the top of a `bloomd.py`.
    ///
    /// Deliberately a small scan rather than a regular expression over the whole file: the literal
    /// is on one line, in one form, and a scanner that reads the first assignment and stops cannot
    /// be fooled by the same words appearing in the docstring below it.
    public static func version(of source: String) -> String? {
        for line in source.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("BLOOMD_VERSION") else { continue }
            guard let open = trimmed.firstIndex(of: "\""),
                  let close = trimmed.lastIndex(of: "\""),
                  open < close else { return nil }
            let value = String(trimmed[trimmed.index(after: open)..<close])
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// The copy inside the running app bundle.
    ///
    /// The same shape as `BridgeRegistration.shimPath`, and for the same two reasons: it is
    /// resolved from the executable rather than through `Bundle.main.url(forResource:)` so that a
    /// pure function can be tested against a made-up layout, and there is an environment override
    /// because `Tools/test-core.sh` mirrors only BloomCore into a package with no app target, so
    /// nothing the suite builds has a bundle to look in.
    public static func sourcePath(
        beside executable: String? = Bundle.main.executableURL?.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let override = environment["BLOOM_BLOOMD_PATH"], !override.isEmpty {
            return FileManager.default.isReadableFile(atPath: override) ? override : nil
        }
        guard let executable else { return nil }
        // Contents/MacOS/Bloom, so the resource is one directory up and along.
        let macos = (executable as NSString).deletingLastPathComponent
        let contents = (macos as NSString).deletingLastPathComponent
        let candidate = (contents as NSString).appendingPathComponent("Resources/bloomd.py")
        return FileManager.default.isReadableFile(atPath: candidate) ? candidate : nil
    }
}

/// What the daemon on a server needs doing to it, worked out before anything is copied.
///
/// A value rather than a branch inside the install, so the pane can say what it is about to do and
/// so the decision is testable without a server. "Copy that file, so it works seamless" is this
/// enum: nobody is ever asked whether to install, and the only case that is not automatic is the
/// one where a copy would not help.
public enum BloomdAction: Sendable, Hashable {
    case upToDate(version: String)
    case install(reason: BloomdReason, version: String)
    /// The server has no Python 3, so there is nothing that could run the file once it arrived.
    case impossible

    public var needsCopying: Bool {
        if case .install = self { return true }
        return false
    }
}

public enum BloomdReason: Sendable, Hashable {
    case notThere
    case differentVersion(String)
    /// The file is there and did not answer with a version, which is a truncated copy or a Python
    /// that could not parse it. Either way the answer is the same file again.
    case unreadable

    public var sentence: String {
        switch self {
        case .notThere: "not installed yet"
        case .differentVersion(let found): "version \(found) is installed"
        case .unreadable: "the installed copy did not answer"
        }
    }
}

public extension Bloomd {
    /// Compares what the bundle ships with what the server reported.
    ///
    /// `hasPython` is a parameter rather than something looked up here, because the probe already
    /// asked and this has to stay a pure function: the whole decision is four lines and the value
    /// of testing it is that nobody has to run a server to find out what it does.
    static func decide(
        shipping local: String,
        installed remote: String?,
        hasPython: Bool
    ) -> BloomdAction {
        guard hasPython else { return .impossible }
        guard let remote, !remote.isEmpty else {
            return .install(reason: .notThere, version: local)
        }
        guard remote == local else {
            return .install(reason: .differentVersion(remote), version: local)
        }
        return .upToDate(version: local)
    }
}

// MARK: - Talking to it

/// Runs `bloomd` on a server, whatever "on a server" turns out to mean.
///
/// It holds a `CommandRunning` rather than an SSH connection, so the same type drives the copy on
/// this Mac. That is not a test convenience: it is how the local and the remote diff pass can
/// eventually be the same code with a different runner behind it.
public struct BloomdClient: Sendable {
    private let runner: any CommandRunning
    /// The remote home directory, from the probe. Everything is addressed from it.
    private let home: String

    public init(runner: any CommandRunning, home: String) {
        self.runner = runner
        self.home = home
    }

    public var remotePath: String { Bloomd.path(inHome: home) }

    /// Copies the file over and checks that the copy answers.
    ///
    /// **The check is the point of the second half.** A `cat` that wrote zero bytes exits zero,
    /// and a server that has just been handed an empty file would then be recorded as running the
    /// version Bloom meant to install. So the version is asked for afterwards, from the file that
    /// is actually there, and a mismatch is a failure rather than a hopeful log line.
    @discardableResult
    public func install(source: String, timeout: Duration = .seconds(30)) async throws -> String {
        try await runner.put(source, at: remotePath, executable: true, timeout: timeout)
        guard let installed = try await version(timeout: timeout) else {
            throw BloomdTrouble.silentAfterInstall
        }
        guard installed == Bloomd.version(of: source) else {
            throw BloomdTrouble.wrongVersionAfterInstall(installed)
        }
        return installed
    }

    /// What the copy on the server says it is, or nil when there is nothing there.
    public func version(timeout: Duration = .seconds(15)) async throws -> String? {
        let result = try await runner.run(command(["version"], timeout: timeout))
        guard result.ok else { return nil }
        let text = result.trimmed
        return text.isEmpty ? nil : text
    }

    /// The several git facts one diff pass needs, in one round trip.
    public func status(
        worktree: String,
        base: String,
        timeout: Duration = .seconds(60)
    ) async throws -> BloomdStatus {
        let result = try await runner.run(
            command(["status", worktree, "--base", base], timeout: timeout)
        )
        return try BloomdStatus.decode(result.stdout, status: result.status)
    }

    /// `python3 <path> <arguments>`, as argv.
    ///
    /// `python3` explicitly rather than relying on the shebang, because the file is installed
    /// under a home directory and a home directory is exactly the kind of mount that gets `noexec`
    /// on a hardened server. Running the interpreter on the file needs no execute bit at all.
    private func command(_ arguments: [String], timeout: Duration) -> CommandLaunch {
        CommandLaunch(
            executable: "python3",
            arguments: [remotePath] + arguments,
            timeout: timeout
        )
    }
}

public enum BloomdTrouble: Error, Sendable, Hashable, CustomStringConvertible {
    case silentAfterInstall
    case wrongVersionAfterInstall(String)
    case refused(String)
    case unreadable(String)

    public var description: String {
        switch self {
        case .silentAfterInstall:
            "The file was copied and then said nothing when it was run. Check that python3 works on that server."
        case .wrongVersionAfterInstall(let found):
            "The file was copied and the server is still running version \(found)."
        case .refused(let message):
            message
        case .unreadable(let head):
            "bloomd answered with something that is not JSON: \(head)"
        }
    }
}

/// One worktree, as the server sees it.
public struct BloomdStatus: Sendable, Hashable, Codable {
    public var version: String
    public var path: String
    public var base: String
    /// Nil when the base branch is not on that server, in which case the counts below are
    /// uncommitted work only. A caller that draws "12 files changed" wants to know which of the
    /// two questions it answered.
    public var mergeBase: String?
    public var branch: String?
    public var head: String?
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    public var changedFiles: Int
    public var additions: Int
    public var deletions: Int
    public var dirty: Bool
    public var files: [BloomdFile]
}

public struct BloomdFile: Sendable, Hashable, Codable {
    public var path: String
    public var oldPath: String?
    public var change: String
    public var additions: Int
    public var deletions: Int
    public var binary: Bool
}

extension BloomdStatus {
    /// Reads one answer.
    ///
    /// The failure blob is decoded before the success one, because `bloomd` reports a bad worktree
    /// as `{"ok": false, "error": ...}` with exit status 1, and that message is the useful thing
    /// on the screen. Anything that is not either shape is quoted back verbatim rather than
    /// summarised, since output nobody anticipated is exactly what somebody debugging needs to see.
    static func decode(_ output: String, status: Int32) throws -> BloomdStatus {
        let data = Data(output.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        if let refusal = try? decoder.decode(BloomdRefusal.self, from: data), !refusal.ok {
            throw BloomdTrouble.refused(refusal.error)
        }
        do {
            return try decoder.decode(BloomdStatus.self, from: data)
        } catch {
            let head = output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)
            throw BloomdTrouble.unreadable(
                head.isEmpty ? "nothing, and it exited \(status)" : String(head)
            )
        }
    }
}

private struct BloomdRefusal: Decodable {
    let ok: Bool
    let error: String
}
