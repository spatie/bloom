import Testing
import Foundation
@testable import BloomCore

/// The state and the sentence a row ends up with, for every way a look can turn out.
///
/// One pure function rather than a message invented at each of the dozen places something can go
/// wrong, which is what lets the pane draw a state and never write English of its own.
@Suite("Server verdict")
struct ServerVerdictTests {
    private func facts(_ output: String) throws -> ServerFacts {
        try ServerProbe.parse(output)
    }

    private func without(_ tool: String, _ output: String = ServerProbeTests.ubuntu) -> String {
        output.components(separatedBy: "\n")
            .map { $0.hasPrefix("tool\t\(tool)\t") ? "tool\t\(tool)\t-\t127\t" : $0 }
            .joined(separator: "\n")
    }

    // MARK: - Reachable

    @Test("git, python3 and a current daemon is ready")
    func ready() throws {
        let clean = ServerProbeTests.ubuntu
            .replacingOccurrences(
                of: "tool\tcodex\t/root/.local/bin/codex\t127\ttimeout: failed to execute process: "
                    + "No such file or directory (os error 2)",
                with: "tool\tcodex\t/usr/bin/codex\t0\tcodex-cli 0.149.0"
            )
            .replacingOccurrences(of: "tool\tgh\t-\t127\t", with: "tool\tgh\t/usr/bin/gh\t0\tgh version 2.88.1")
        let verdict = ServerVerdict.reached(
            facts: try facts(clean),
            action: .upToDate(version: "1")
        )
        #expect(verdict == ServerVerdict(state: .ready, detail: ""))
    }

    /// A server is ready with no agent on it. An agent is installed per project and this pane is
    /// about the machine, so a missing one is a note in the sentence rather than a blocked row.
    @Test("a missing agent is a note, not a blocker")
    func missingAgentIsANote() throws {
        let verdict = ServerVerdict.reached(
            facts: try facts(without("claude", without("codex", without("gh")))),
            action: .upToDate(version: "1")
        )
        #expect(verdict.state == .ready)
        #expect(verdict.detail == "No Claude Code, Codex and GitHub CLI on it.")
    }

    /// The state that looks like success from a distance, so it gets said out loud even when
    /// everything else is fine. This is the real broken `codex` from the Ubuntu fixture.
    @Test("a tool that is there and does not run is said out loud")
    func brokenToolIsMentioned() throws {
        let verdict = ServerVerdict.reached(
            facts: try facts(ServerProbeTests.ubuntu),
            action: .upToDate(version: "1")
        )
        #expect(verdict.state == .ready)
        #expect(verdict.detail == "Codex is installed and did not run.")
    }

    @Test("no git is a server Bloom cannot put a worktree on")
    func noGit() throws {
        let verdict = ServerVerdict.reached(
            facts: try facts(without("git")),
            action: .upToDate(version: "1")
        )
        #expect(verdict == ServerVerdict(state: .incomplete, detail: "git is not installed."))
    }

    /// `bloomd` is a Python file, so a server with no Python is one Bloom can look at and cannot
    /// install anything on.
    @Test("no python3 is named alongside git rather than instead of it")
    func noGitAndNoPython() throws {
        let verdict = ServerVerdict.reached(
            facts: try facts(without("python3", without("git"))),
            action: .impossible
        )
        #expect(verdict.state == .incomplete)
        #expect(verdict.detail == "git and python3 are not installed.")
    }

    // MARK: - Failed

    @Test("every connection failure becomes an unreachable row with a sentence")
    func connectionFailures() {
        for failure: SSHFailure in [
            .hostKeyUnknown, .hostKeyChanged, .authenticationRefused("publickey"),
            .connectionRefused, .hostNotFound, .timedOut, .networkUnreachable,
            .closedByRemote, .clientMissing, .connectionDropped, .other("odd"),
        ] {
            let verdict = ServerVerdict.failed(RunTrouble.unreachable(failure))
            #expect(verdict.state == .unreachable)
            #expect(verdict.detail == failure.sentence)
            #expect(!verdict.detail.isEmpty)
        }
    }

    /// An unknown host key gets the sentence that names the fix, because the fix is a person
    /// opening a terminal and looking at a fingerprint once.
    @Test("an unknown host key tells you what to do about it")
    func hostKeySentence() {
        let verdict = ServerVerdict.failed(RunTrouble.unreachable(.hostKeyUnknown))
        #expect(verdict.detail.contains("known_hosts"))
        #expect(verdict.detail.contains("terminal"))
    }

    @Test("a timeout is unreachable and says how long it waited")
    func timeout() {
        let verdict = ServerVerdict.failed(RunTrouble.timedOut(.seconds(20)))
        #expect(verdict.state == .unreachable)
        #expect(verdict.detail.contains("20"))
    }

    /// A truncated probe is the link dropping. A probe that answered and answered oddly is a
    /// server that needs setting up, and the two want different rows.
    @Test("a truncated probe is a network problem and a strange one is a setup problem")
    func probeTrouble() {
        #expect(ServerVerdict.failed(ServerProbe.Trouble.truncated).state == .unreachable)
        #expect(
            ServerVerdict.failed(ServerProbe.Trouble.notAProbe("This account is restricted."))
                .state == .incomplete
        )
        #expect(
            ServerVerdict.failed(ServerProbe.Trouble.notAProbe("This account is restricted."))
                .detail.contains("This account is restricted.")
        )
    }

    @Test("a daemon that could not be installed leaves the server incomplete")
    func bloomdTrouble() {
        let verdict = ServerVerdict.failed(BloomdTrouble.silentAfterInstall)
        #expect(verdict.state == .incomplete)
        #expect(verdict.detail.contains("python3"))
    }

    /// Whatever it was, the row ends up with something a person can read. An empty detail on an
    /// unreachable row is a row nobody can act on.
    @Test("an error nobody anticipated still produces a sentence")
    func unanticipated() {
        struct Odd: Error {}
        let verdict = ServerVerdict.failed(Odd())
        #expect(verdict.state == .unreachable)
        #expect(!verdict.detail.isEmpty)
    }
}
