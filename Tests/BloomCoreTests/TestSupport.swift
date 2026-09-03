import Foundation
import Testing
@testable import BloomCore

// MARK: - Tags

extension Tag {
    /// Drives the real `git` binary against a real repository on disk.
    @Tag static var git: Self
    /// Exercises a path that deletes something. If one of these is wrong, work is gone.
    @Tag static var destructive: Self
    /// Decodes or renders bytes the agent CLI produced.
    @Tag static var agentProtocol: Self
    /// Spawns a subprocess or waits on one, so it is slower than a unit test.
    @Tag static var subprocess: Self
    /// Pins something about credentials, hostile input or option injection.
    @Tag static var security: Self
    /// Reads or writes the SQLite store.
    @Tag static var persistence: Self
}

// MARK: - Per-process scratch directory

/// The one directory a test run owns, removed when the process exits.
///
/// **Everything a test writes has to end up under here, and this is the second half of a bug the
/// per-test directory below only half closed.** That one removes what a test wrote when the test
/// ends, and it works; what it cannot cover is the two things that deliberately outlive a single
/// test: the fallback for a suite that forgot the trait, and the built repository templates,
/// which are shared by every test in the process. Nothing removed either, so each run of the
/// suite left them behind, and a machine that runs this suite all day was found with **9,468
/// `bloom-unscoped-` directories and 219 template roots** in its temporary directory. That is a
/// leak per run, not a leak per test, which is why it went unnoticed for so long: it is invisible
/// until somebody counts, and by then it is 300,000 files.
///
/// Named by process id and swept at exit through `atexit`, which takes a C function and therefore
/// captures nothing: the path is derived again inside the handler from the same two pieces it was
/// built from. A run killed with SIGKILL still leaves its directory, which is what
/// `Tools/test-core.sh` sweeps on its way in.
enum TestProcessScratch {
    /// The root, created once.
    static let root: String = {
        let path = Self.path(pid: getpid())
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        atexit {
            // No capture: a C function pointer cannot have one, and this needs none.
            try? FileManager.default.removeItem(atPath: TestProcessScratch.path(pid: getpid()))
        }
        return path
    }()

    /// A directory inside it, with a name of its own.
    static func directory(_ prefix: String) -> String {
        let path = (root as NSString).appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// Where a run of this process id keeps its scratch. `Tools/test-core.sh` knows this shape,
    /// so the prefix is worth keeping stable.
    static func path(pid: pid_t) -> String {
        NSTemporaryDirectory() + "bloom-test-run-\(pid)"
    }
}

// MARK: - Per-test scratch directory

/// The directory the running test owns.
///
/// Every test used to build its own path straight under `NSTemporaryDirectory()` and nothing ever
/// removed it. On the machine where this was found that had left 13,229 stray `.sqlite` files and
/// 1,046 abandoned worktrees behind. Scoping the directory to the test means a test that fails
/// half way through still leaves nothing.
enum TestScratch {
    @TaskLocal static var directory: String?

    /// A path inside the running test's directory. Falls back to a fresh unique directory so a
    /// test that forgot the trait still cannot collide with a parallel one.
    static func path(_ name: String) -> String {
        // Under the process's own root, so a test that forgot the trait costs a directory for the
        // length of the run rather than one left on the machine for ever. See
        // `TestProcessScratch`.
        let root = directory ?? TestProcessScratch.directory("unscoped")
        return (root as NSString).appendingPathComponent(name)
    }

    /// A path with a unique name inside the running test's directory.
    static func unique(_ prefix: String) -> String {
        path("\(prefix)-\(UUID().uuidString)")
    }
}

/// One built repository per default branch, kept for the life of the test process.
///
/// An actor because the whole point is that the build happens once however many tests ask at the
/// same moment, and `TempRepo` is already `async`. It lives outside every test's scratch
/// directory, since those are deleted per test and this outlives all of them.
actor RepoTemplate {
    static let shared = RepoTemplate()

    /// The in-flight build rather than the finished path, which is the whole of the
    /// synchronisation. An actor is re-entrant across `await`, and building a repository is four
    /// of them, so a dictionary of finished paths let two hundred tests all look, all find
    /// nothing, and all run `git init` into the same directory. Storing the `Task` happens with
    /// no suspension between the look and the write, so every caller after the first waits on the
    /// same build. `AgentCatalog` shares a detection the same way and for the same reason.
    private var building: [String: Task<String, Error>] = [:]
    /// Outside every test's scratch directory, since those are deleted per test and this outlives
    /// all of them, and inside the process's, which is deleted when the run ends.
    private let root = TestProcessScratch.directory("repo-templates")

    func path(defaultBranch: String) async throws -> String {
        if let inFlight = building[defaultBranch] { return try await inFlight.value }
        let root = root
        let index = building.count
        let task = Task { try await Self.build(defaultBranch: defaultBranch, at: root, index: index) }
        building[defaultBranch] = task
        return try await task.value
    }

    private static func build(defaultBranch: String, at root: String, index: Int) async throws -> String {
        let directory = (root as NSString)
            .appendingPathComponent("template-\(index)-\(defaultBranch)")
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        try await Shell.check("git", ["init", "-q", "-b", defaultBranch], cwd: directory)
        // Written rather than set through three `git config` processes, which is exactly what
        // `git config` would have done to this file and 555 forks cheaper across the suite.
        let config = (directory as NSString).appendingPathComponent(".git/config")
        let identity = """

            [user]
            \temail = test@bloom.local
            \tname = Bloom Test
            [commit]
            \tgpgsign = false

            """
        let existing = (try? String(contentsOfFile: config, encoding: .utf8)) ?? ""
        try (existing + identity).write(toFile: config, atomically: true, encoding: .utf8)

        try "hello\n".write(
            toFile: (directory as NSString).appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try await Shell.check("git", ["add", "-A"], cwd: directory)
        try await Shell.check("git", ["commit", "-q", "-m", "initial"], cwd: directory)
        return directory
    }
}

/// Gives each test its own scratch directory and deletes it afterwards, pass or fail.
struct ScratchDirectoryTrait: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: () async throws -> Void
    ) async throws {
        // Applied to a suite, this fires once for the suite itself with no test case, and again
        // for every test inside it. Only the per-test scope is worth a directory.
        guard testCase != nil else {
            try await function()
            return
        }

        let root = (TestProcessScratch.root as NSString)
            .appendingPathComponent("scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)

        do {
            try await TestScratch.$directory.withValue(root) {
                try await function()
            }
        } catch {
            await remove(root)
            throw error
        }
        await remove(root)
    }

    /// SQLite keeps writing its `-wal` and `-shm` sidecars from whatever task still holds the
    /// connection, and the agent runner persists some bookkeeping from a detached task, so the
    /// directory can reappear microseconds after being deleted. One run in twelve left a stray
    /// directory behind because of exactly that. Retrying costs nothing.
    private func remove(_ path: String) async {
        for attempt in 0..<4 {
            try? FileManager.default.removeItem(atPath: path)
            guard FileManager.default.fileExists(atPath: path) else { return }
            try? await Task.sleep(for: .milliseconds(25 * (attempt + 1)))
        }
        try? FileManager.default.removeItem(atPath: path)
    }
}

extension Trait where Self == ScratchDirectoryTrait {
    /// Scopes `TestScratch` to this test, and removes everything it wrote when it finishes.
    static var scratchDirectory: Self { Self() }
}

/// A SQLite store in the running test's scratch directory.
func makeTestStore(_ label: String = "store") throws -> Store {
    try Store(path: TestScratch.unique(label) + ".sqlite")
}

// MARK: - Waiting

/// Polls until `condition` holds, and says what it was waiting for if it never does.
///
/// The bare poll loops this replaced simply gave up after their last iteration, which left the
/// *next* expectation to fail with a message about the wrong thing entirely.
func waitUntil(
    _ description: Comment,
    within timeout: Duration = .seconds(6),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @Sendable () async -> Bool
) async {
    let step = Duration.milliseconds(10)
    let attempts = max(1, Int(timeout / step))
    for _ in 0..<attempts {
        if await condition() { return }
        try? await Task.sleep(for: step)
    }
    Issue.record("timed out after \(timeout) waiting until \(description)", sourceLocation: sourceLocation)
}

// MARK: - Temporary git repository

/// A throwaway git repository on disk. These tests run real git, because the whole point of
/// Git.swift is that it drives the real thing correctly.
struct TempRepo {
    let path: String

    /// Copied from a template rather than built, which is what makes the suite bearable.
    ///
    /// Building one repository is six `git` processes: init, three configs, add and commit. The
    /// suite makes about 190 of them, and a fork on this machine costs roughly twelve
    /// milliseconds, so those six were a fifth of every `git` process the whole run spawned and a
    /// third of its system time. A repository with one commit in it is a directory of small files
    /// with nothing absolute in it, so the first one is built and the rest are copied.
    ///
    /// The commit hash is therefore the same in every repository cut from the same template.
    /// Nothing compares a revision across two repositories, and a test that wants two distinct
    /// histories makes its own commits on top, which are unique because their timestamps are.
    init(defaultBranch: String = "main") async throws {
        let template = try await RepoTemplate.shared.path(defaultBranch: defaultBranch)
        path = TestScratch.unique("bloom-git")
        try FileManager.default.copyItem(atPath: template, toPath: path)
    }

    /// Wraps a directory that is already a worktree, so the write helpers can be reused.
    init(existing path: String) {
        self.path = path
    }

    func write(_ relative: String, _ contents: String) throws {
        let full = (path as NSString).appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try contents.write(toFile: full, atomically: true, encoding: .utf8)
    }

    func read(_ relative: String) -> String? {
        try? String(contentsOfFile: (path as NSString).appendingPathComponent(relative), encoding: .utf8)
    }

    func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(relative))
    }

    func commit(_ message: String) async throws {
        try await Shell.check("git", ["add", "-A"], cwd: path)
        try await Shell.check("git", ["commit", "-q", "-m", message], cwd: path)
    }

    /// Deletes the repository, every worktree linked to it, and the folder `WorkspaceManager`
    /// puts those worktrees in.
    ///
    /// Cleanup has to be synchronous. Several tests used to spell it
    /// `defer { Task { try? await Git.removeWorktree(...) } }`, which is a detached task: the
    /// test returns, the enclosing `defer` deletes the repository out from under it, and the
    /// removal then fails with nobody watching. That had left 1,046 abandoned directories under
    /// `~/bloom/workspaces` on the machine where it was found. Reading the worktree list here
    /// also covers worktrees the test never named.
    func cleanUp() {
        for worktree in linkedWorktrees() {
            try? FileManager.default.removeItem(atPath: worktree)
        }
        // `WorkspaceManager.workspacesRoot` is not injectable, so created workspaces land under
        // the real home directory. The per-repo folder is named after this unique directory.
        let managed = WorkspaceManager.workspacesRoot
            .appendingPathComponent((path as NSString).lastPathComponent, isDirectory: true)
        try? FileManager.default.removeItem(at: managed)
        try? FileManager.default.removeItem(atPath: path)
    }

    /// `git worktree list --porcelain` prints one `worktree <path>` line per checkout, the first
    /// of which is this repository itself.
    private func linkedWorktrees() -> [String] {
        guard let output = try? runGit(["worktree", "list", "--porcelain"]) else { return [] }
        let mine = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return output
            .components(separatedBy: "\n")
            .filter { $0.hasPrefix("worktree ") }
            .map { String($0.dropFirst("worktree ".count)) }
            .filter { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path != mine }
    }

    /// Synchronous on purpose: it is called from `defer`, where nothing can be awaited.
    private func runGit(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: path)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Fixtures

/// The captured sessions live in `Tests/fixtures`, not in a resource bundle, so they are found by
/// walking up from this file. Symlinks are resolved too, because the core suite is run from a mirrored
/// package that has no app target (see Tools/test-core.sh).
func bloomFixtureLines(_ name: String) throws -> [String] {
    let starts = [
        URL(fileURLWithPath: #filePath),
        URL(fileURLWithPath: #filePath).resolvingSymlinksInPath(),
    ]

    for start in starts {
        var directory = start.deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent("fixtures").appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
                    .components(separatedBy: "\n")
                    .filter { $0.isEmpty == false }
            }
            directory = directory.deletingLastPathComponent()
        }
    }

    throw CocoaError(.fileNoSuchFile)
}

// MARK: - Output collection

/// Collects streamed script output from a `@Sendable` callback.
final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock(); lines.append(line); lock.unlock()
    }

    var joined: String {
        lock.lock(); defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Readable failures

// Same package, so no @retroactive is needed or allowed here.
/// Without this, a failed archive expectation prints every stored property of the report and
/// buries the one thing the reader needs: what archiving would have destroyed.
extension WorkspaceSafetyReport: CustomTestStringConvertible {
    public var testDescription: String {
        isSafeToDiscard
            ? "safe to discard"
            : "would destroy " + losses.joined(separator: "; ")
    }
}

/// Events print as the line the CLI actually emitted, which is what a decoding failure is about.
extension AgentEvent: CustomTestStringConvertible {
    public var testDescription: String {
        let body = String(decoding: raw.prefix(160), as: UTF8.self)
        return body.isEmpty ? "\(kind)" : "\(kind) \(body)"
    }
}
