import Testing
import Foundation
@testable import BloomCore

/// A runner that starts no process, so the whole of probe, decide, install and verdict can be
/// driven without a server.
///
/// The same trick as `AgentRunnerTests`' fake process, and for the same reason: the seam exists so
/// that the sequencing above it is testable, and a test that needs a VPS is a test that fails on a
/// plane. It records what it was asked, which is how the "and nothing was copied" assertions are
/// made at all.
final class FakeRunner: CommandRunning, @unchecked Sendable {
    struct Put: Sendable, Hashable {
        var path: String
        var contents: String
        var executable: Bool
    }

    let place = RunPlace.ssh(SSHDestination(user: "deploy", host: "vps.example.com"))

    private let lock = NSLock()
    private var _launches: [CommandLaunch] = []
    private var _puts: [Put] = []
    /// Answers, in the order they will be handed out, keyed by the first argument that identifies
    /// the call. A closure rather than a table so a test can change its mind between calls, which
    /// is what an install needs: `version` answers nothing, then something.
    private let answer: @Sendable (CommandLaunch, Int) -> Result<ShellResult, any Error>

    init(answer: @escaping @Sendable (CommandLaunch, Int) -> Result<ShellResult, any Error>) {
        self.answer = answer
    }

    var launches: [CommandLaunch] { lock.withLock { _launches } }
    var puts: [Put] { lock.withLock { _puts } }

    func run(_ launch: CommandLaunch) async throws -> ShellResult {
        let index = lock.withLock { () -> Int in
            _launches.append(launch)
            return _launches.count - 1
        }
        return try answer(launch, index).get()
    }

    func put(_ contents: String, at path: String, executable: Bool, timeout: Duration) async throws {
        lock.withLock {
            _puts.append(Put(path: path, contents: contents, executable: executable))
        }
    }
}

/// Everything one look at a server does, end to end, with nothing on the network.
@Suite("Server checkup")
struct ServerCheckupTests {
    /// The real Ubuntu probe output, with the daemon line swapped for whatever a case needs.
    private static func probeOutput(bloomd: String) -> String {
        ServerProbeTests.ubuntu.replacingOccurrences(
            of: "bloomd\t/root/.bloom/bin/bloomd\t1",
            with: bloomd
        )
    }

    private static func ok(_ stdout: String) -> Result<ShellResult, any Error> {
        .success(ShellResult(status: 0, stdout: stdout, stderr: ""))
    }

    private static let shipping = "BLOOMD_VERSION = \"2\"\n# the file\n"

    // MARK: - Installing

    /// The whole of "copy that file, so it works seamless": nobody is asked, the file goes over on
    /// the connection that is already open, and it is verified by running it afterwards.
    @Test("a server with no daemon gets one, unasked")
    func installsOnAFreshServer() async throws {
        let runner = FakeRunner { launch, _ in
            if launch.arguments.contains("version") {
                // Before the copy there is nothing; after it, version 2. The fake answers by
                // looking at what has been put, which is what makes this one closure rather than
                // a script of canned replies.
                return .success(ShellResult(status: 0, stdout: "2\n", stderr: ""))
            }
            return .success(ShellResult(
                status: 0,
                stdout: ServerProbeTests.ubuntu.replacingOccurrences(
                    of: "bloomd\t/root/.bloom/bin/bloomd\t1",
                    with: "bloomd\t-\t-"
                ),
                stderr: ""
            ))
        }

        let outcome = try await ServerCheckup(runner: runner, source: Self.shipping).run()

        #expect(outcome.action == .install(reason: .notThere, version: "2"))
        #expect(outcome.bloomdVersion == "2")
        #expect(outcome.verdict.state == .ready)

        let put = try #require(runner.puts.first)
        #expect(put.path == "/root/.bloom/bin/bloomd")
        #expect(put.contents == Self.shipping)
        #expect(put.executable)
        #expect(runner.puts.count == 1)
    }

    /// The case that runs on every look, so it has to be free.
    @Test("a server already on this version is not written to")
    func currentServerIsLeftAlone() async throws {
        let runner = FakeRunner { _, _ in
            Self.ok(Self.probeOutput(bloomd: "bloomd\t/root/.bloom/bin/bloomd\t2"))
        }
        let outcome = try await ServerCheckup(runner: runner, source: Self.shipping).run()

        #expect(outcome.action == .upToDate(version: "2"))
        #expect(runner.puts.isEmpty)
        // One round trip for the whole checkup, which is the requirement.
        #expect(runner.launches.count == 1)
    }

    @Test("an older daemon is replaced")
    func olderDaemonIsReplaced() async throws {
        let runner = FakeRunner { launch, _ in
            launch.arguments.contains("version")
                ? Self.ok("2\n")
                : Self.ok(Self.probeOutput(bloomd: "bloomd\t/root/.bloom/bin/bloomd\t1"))
        }
        let outcome = try await ServerCheckup(runner: runner, source: Self.shipping).run()
        #expect(outcome.action == .install(reason: .differentVersion("1"), version: "2"))
        #expect(runner.puts.count == 1)
    }

    /// A `cat` that wrote zero bytes exits zero. Without this check the row would say the server
    /// is running the version Bloom meant to install, which it is not.
    @Test("a copy that did not take is a failure, not a hopeful log line")
    func silentAfterInstall() async {
        let runner = FakeRunner { launch, _ in
            launch.arguments.contains("version")
                ? .success(ShellResult(status: 1, stdout: "", stderr: ""))
                : Self.ok(Self.probeOutput(bloomd: "bloomd\t-\t-"))
        }
        await #expect(throws: BloomdTrouble.silentAfterInstall) {
            try await ServerCheckup(runner: runner, source: Self.shipping).run()
        }
    }

    @Test("a server still on the old version after a copy is a failure")
    func wrongVersionAfterInstall() async {
        let runner = FakeRunner { launch, _ in
            launch.arguments.contains("version")
                ? Self.ok("1\n")
                : Self.ok(Self.probeOutput(bloomd: "bloomd\t-\t-"))
        }
        await #expect(throws: BloomdTrouble.wrongVersionAfterInstall("1")) {
            try await ServerCheckup(runner: runner, source: Self.shipping).run()
        }
    }

    @Test("a server with no python3 is not written to")
    func noPythonNoInstall() async throws {
        let runner = FakeRunner { _, _ in
            Self.ok(
                Self.probeOutput(bloomd: "bloomd\t-\t-").replacingOccurrences(
                    of: "tool\tpython3\t/usr/bin/python3\t0\tPython 3.14.4",
                    with: "tool\tpython3\t-\t127\t"
                )
            )
        }
        let outcome = try await ServerCheckup(runner: runner, source: Self.shipping).run()
        #expect(outcome.action == .impossible)
        #expect(outcome.verdict.state == .incomplete)
        #expect(runner.puts.isEmpty)
    }

    /// A broken build rather than a broken server, and the row has to say which.
    @Test("a Bloom with no bloomd.py of its own says so")
    func missingSource() async throws {
        let runner = FakeRunner { _, _ in Self.ok(Self.probeOutput(bloomd: "bloomd\t-\t-")) }
        let outcome = try await ServerCheckup(runner: runner, source: nil).run()
        #expect(outcome.verdict.state == .incomplete)
        #expect(outcome.verdict.detail.contains("This copy of Bloom"))
        #expect(runner.puts.isEmpty)
    }

    // MARK: - What the probe was asked

    /// The probe crosses as a script on stdin, which is what makes it one round trip and what
    /// means nothing in it has to survive two rounds of shell quoting.
    @Test("the probe goes over on stdin, not as an argument")
    func probeIsAScriptOnStdin() async throws {
        let runner = FakeRunner { _, _ in Self.ok(Self.probeOutput(bloomd: "bloomd\t-\t-")) }
        _ = try? await ServerCheckup(runner: runner, source: nil).run()

        let launch = try #require(runner.launches.first)
        #expect(launch.executable == "sh")
        #expect(launch.arguments == ["-s"])
        #expect(launch.stdin == ServerProbe.script)
        #expect(launch.timeout == ServerProbe.timeout)
    }

    /// A home directory is a fact the probe brings back, so nothing has to guess it, and the path
    /// is absolute because `~` does not survive being quoted for the remote shell.
    @Test("the daemon is addressed by an absolute path from the probe's own answer")
    func daemonPathComesFromTheProbe() async throws {
        let runner = FakeRunner { launch, _ in
            launch.arguments.contains("version")
                ? Self.ok("2\n")
                : Self.ok(
                    Self.probeOutput(bloomd: "bloomd\t-\t-")
                        .replacingOccurrences(of: "home\t/root", with: "home\t/home/deploy")
                )
        }
        _ = try await ServerCheckup(runner: runner, source: Self.shipping).run()

        #expect(runner.puts.first?.path == "/home/deploy/.bloom/bin/bloomd")
        let versionCall = try #require(runner.launches.first { $0.arguments.contains("version") })
        // python3 explicitly, because a home directory is exactly the kind of mount that gets
        // `noexec` and the shebang would then be no help.
        #expect(versionCall.executable == "python3")
        #expect(versionCall.arguments == ["/home/deploy/.bloom/bin/bloomd", "version"])
    }
}
