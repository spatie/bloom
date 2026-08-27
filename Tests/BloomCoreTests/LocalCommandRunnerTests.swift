import Testing
import Foundation
@testable import BloomCore

/// The seam's local end, driven for real.
///
/// **This is the offline half of the server feature, and it is not a token test.** The probe
/// script, the daemon install and `bloomd` itself all run here, on this machine, through the same
/// `CommandRunning` the SSH conformance implements. A Mac is also the awkward distribution: no
/// `/etc/os-release`, `arm64` rather than `aarch64`, and a `df` whose data volume is not at `/`.
/// So a script that only ever worked on Ubuntu fails here rather than in front of a user.
///
/// Nothing in this file reaches a network, and nothing in it asserts a fact about the owner's
/// machine beyond "it has git and a shell", which any machine that can build Bloom has.
@Suite("Local command runner", .tags(.subprocess), .scratchDirectory)
struct LocalCommandRunnerTests {
    @Test("a command runs and its output comes back")
    func runsACommand() async throws {
        let result = try await LocalCommandRunner().run(
            CommandLaunch(executable: "echo", arguments: ["hello"], timeout: .seconds(10))
        )
        #expect(result.ok)
        #expect(result.trimmed == "hello")
    }

    /// A script on stdin needs no quoting at all, which is why the probe crosses that way.
    @Test("a script crosses on stdin")
    func scriptOnStdin() async throws {
        let result = try await LocalCommandRunner().run(
            .script("printf 'a\\tb\\n'; printf 'it is here\\n'", timeout: .seconds(10))
        )
        #expect(result.stdout == "a\tb\nit is here\n")
    }

    /// The whole probe, against this Mac. What is asserted is the shape rather than which tools
    /// this particular machine has, because the machine running the suite is not the machine
    /// anybody is developing on.
    @Test("the probe script runs and parses on a Mac")
    func probeRunsHere() async throws {
        let facts = try await ServerProbe(runner: LocalCommandRunner()).run()

        #expect(facts.formatVersion == ServerProbe.format)
        #expect(facts.system == "Darwin")
        #expect(!facts.architecture.isEmpty)
        // sw_vers rather than /etc/os-release, which is the fallback a Mac exercises and Ubuntu
        // never reaches.
        #expect(facts.osName.contains("macOS"))
        #expect(facts.home == NSHomeDirectory())
        #expect(!facts.loginPath.isEmpty)
        #expect(facts.searchPath.count > facts.loginPath.count)

        // Anything that can build Bloom has git, and a machine reporting no free disk at all has
        // gone wrong in a way worth failing over.
        #expect(facts.state(of: .git).isPresent)
        #expect(facts.diskAvailableBytes > 0)
        #expect(facts.diskTotalBytes > facts.diskAvailableBytes)
        #expect(!facts.diskMount.isEmpty)

        // Every tool asked about is answered about, present or not.
        #expect(facts.findings.map(\.tool) == ServerTool.displayOrder)
    }

    // MARK: - Putting a file somewhere

    /// The first install is the one a fresh server takes, and it is the one that used to fail:
    /// `replaceItemAt` refuses when the destination does not exist.
    @Test("a file lands where there was no directory at all")
    func firstInstall() async throws {
        let home = TestScratch.unique("home")
        let path = Bloomd.path(inHome: home)
        #expect(!FileManager.default.fileExists(atPath: path))

        try await LocalCommandRunner().put(
            "BLOOMD_VERSION = \"1\"\n", at: path, executable: true, timeout: .seconds(10)
        )

        #expect(try String(contentsOfFile: path, encoding: .utf8) == "BLOOMD_VERSION = \"1\"\n")
        #expect(FileManager.default.isExecutableFile(atPath: path))
    }

    @Test("a second copy replaces the first and leaves nothing behind")
    func secondInstall() async throws {
        let home = TestScratch.unique("home")
        let path = Bloomd.path(inHome: home)
        let runner = LocalCommandRunner()

        try await runner.put("one\n", at: path, executable: true, timeout: .seconds(10))
        try await runner.put("two\n", at: path, executable: true, timeout: .seconds(10))

        #expect(try String(contentsOfFile: path, encoding: .utf8) == "two\n")
        let directory = (path as NSString).deletingLastPathComponent
        let left = try FileManager.default.contentsOfDirectory(atPath: directory)
        #expect(left == ["bloomd"])
    }

    // MARK: - The daemon itself

    /// **The end to end proof, with no server in it.** The file this build ships is installed
    /// through the seam, run through the seam, and asked about a real git repository, and its
    /// answer is decoded by the type the app uses. If `bloomd.py` were broken, this is what says
    /// so, and it says so without a network.
    @Test("the shipped bloomd installs, answers, and reports on a real worktree", .tags(.git))
    func daemonEndToEnd() async throws {
        let source = try #require(
            bloomdSourcePath().flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        )
        let home = TestScratch.unique("home")
        let client = BloomdClient(runner: LocalCommandRunner(), home: home)

        // Nothing there to begin with.
        let before = try await client.version()
        #expect(before == nil)

        let installed = try await client.install(source: source)
        #expect(installed == Bloomd.version(of: source))

        // A second install of the same version is a decision, not a copy. See `Bloomd.decide`.
        let reported = try await client.version()
        #expect(reported == installed)
        #expect(
            Bloomd.decide(shipping: installed, installed: reported, hasPython: true)
                == .upToDate(version: installed)
        )

        // And now a real repository, with a real uncommitted change in it.
        let repo = try await TempRepo(defaultBranch: "main")
        try await Shell.check("git", ["checkout", "-q", "-b", "feature"], cwd: repo.path)
        let file = (repo.path as NSString).appendingPathComponent("a file with spaces.txt")
        try "one\ntwo\n".write(toFile: file, atomically: true, encoding: .utf8)

        let status = try await client.status(worktree: repo.path, base: "main")
        #expect(status.version == installed)
        #expect(status.branch == "feature")
        #expect(status.head?.isEmpty == false)
        #expect(status.dirty)
        #expect(status.changedFiles == 1)
        #expect(status.additions == 2)
        #expect(status.files.first?.path == "a file with spaces.txt")
        #expect(status.files.first?.change == "untracked")
    }

    @Test("the daemon refuses a path that is not a worktree, in words")
    func daemonRefusal() async throws {
        let source = try #require(
            bloomdSourcePath().flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        )
        let home = TestScratch.unique("home")
        let client = BloomdClient(runner: LocalCommandRunner(), home: home)
        try await client.install(source: source)

        await #expect(throws: (any Error).self) {
            _ = try await client.status(worktree: TestScratch.unique("nope"), base: "main")
        }
    }
}
