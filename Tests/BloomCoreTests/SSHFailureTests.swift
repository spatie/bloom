import Testing
import Foundation
@testable import BloomCore

/// Reading what `ssh` printed.
///
/// **Every string in this file was produced by a real OpenSSH 10.3 client talking to a real
/// server**, captured while this was built, rather than written from memory. That matters more
/// here than anywhere else in the feature: the whole type is a set of substring matches, and a
/// substring match against remembered text is a test that passes and a product that does not.
@Suite("SSH failure", .tags(.security))
struct SSHFailureTests {
    /// The default `StrictHostKeyChecking=ask` under `BatchMode=yes`, against a host that is not
    /// in `known_hosts`. This is the whole of what it says.
    @Test("an unknown host key is refused rather than prompted for")
    func unknownHostKey() {
        let failure = SSHFailure.classify(
            status: 255,
            stderr: "Host key verification failed.\n"
        )
        #expect(failure == .hostKeyUnknown)
        #expect(failure?.isWorthRetrying == false)
        #expect(failure?.sentence.contains("known_hosts") == true)
    }

    /// A changed key prints the unknown key's phrase too, at the bottom, under a banner of at
    /// signs. So the specific one has to be looked for first, and this is that ordering pinned.
    @Test("a changed host key is told apart from an unknown one")
    func changedHostKey() {
        let stderr = """
            @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
            @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
            @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
            IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!
            Someone could be eavesdropping on you right now (man-in-the-middle attack)!
            It is also possible that a host key has just been changed.
            The fingerprint for the ED25519 key sent by the remote host is
            SHA256:Ma87peqR6XcrIZCKfHOglJFpgy2XCzNyraPX18eNeJk.
            Please contact your system administrator.
            Add correct host key in /Users/someone/.ssh/known_hosts to get rid of this message.
            Offending ED25519 key in /Users/someone/.ssh/known_hosts:1
            Host key for vps.example.com has changed and you have requested strict checking.
            Host key verification failed.

            """
        let failure = SSHFailure.classify(status: 255, stderr: stderr)
        #expect(failure == .hostKeyChanged)
        #expect(failure?.isWorthRetrying == false)
    }

    @Test("an unknown user is an authentication refusal, with the methods named")
    func permissionDenied() {
        let failure = SSHFailure.classify(
            status: 255,
            stderr: "nosuchuser@94.237.125.23: Permission denied (publickey).\n"
        )
        #expect(failure == .authenticationRefused("publickey"))
        #expect(failure?.sentence.contains("publickey") == true)
    }

    @Test("the connection failures, as macOS words them")
    func connectionFailures() {
        #expect(
            SSHFailure.classify(
                status: 255,
                stderr: "ssh: connect to host 192.0.2.1 port 22: Operation timed out\n"
            ) == .timedOut
        )
        #expect(
            SSHFailure.classify(
                status: 255,
                stderr: "ssh: Could not resolve hostname bloom-nothing-here.invalid: "
                    + "nodename nor servname provided, or not known\n"
            ) == .hostNotFound
        )
        #expect(
            SSHFailure.classify(
                status: 255,
                stderr: "ssh: connect to host 127.0.0.1 port 2222: Connection refused\n"
            ) == .connectionRefused
        )
    }

    /// Linux words two of those differently, and Bloom sits on a Mac talking to Linux boxes.
    @Test("the same failures, as Linux words them")
    func connectionFailuresOnLinux() {
        #expect(
            SSHFailure.classify(
                status: 255,
                stderr: "ssh: Could not resolve hostname vps: Name or service not known\n"
            ) == .hostNotFound
        )
        #expect(
            SSHFailure.classify(
                status: 255,
                stderr: "ssh: connect to host vps port 22: Connection timed out\n"
            ) == .timedOut
        )
    }

    /// Measured: SIGKILL the multiplexing master while a command is running on it and the command
    /// ends with status 255 and nothing at all on either stream. It used to come out as
    /// `other("")`, whose sentence was "ssh failed and said nothing".
    @Test("a master killed underneath a command is a dropped connection")
    func masterKilled() {
        let failure = SSHFailure.classify(status: 255, stderr: "")
        #expect(failure == .connectionDropped)
        #expect(failure?.isWorthRetrying == true)
        #expect(failure?.sentence.isEmpty == false)
    }

    /// **The one that would have broken everything quietly.** Past `sshd`'s `MaxSessions` of 10,
    /// the eleventh channel writes these two lines to stderr, opens a connection of its own, runs
    /// the command and exits 0. Anything that read stderr as evidence of failure would report a
    /// perfectly good server as broken under load, which is exactly when it matters.
    @Test("the multiplexing fallback is not a failure")
    func multiplexingFallbackIsNotAFailure() {
        let stderr = """
            mux_client_request_session: session request failed: Session open refused by peer
            ControlSocket /Users/freek/.bloom/ssh/9c7aa124dbd1486e5731a202dce2625dc1a0fcef \
            already exists, disabling multiplexing

            """
        #expect(SSHFailure.classify(status: 0, stderr: stderr) == nil)
    }

    /// `ssh` exits with the REMOTE command's status. A probe that found no `claude` comes back
    /// non-zero and has nothing to do with the connection.
    @Test("a remote command's own failure is not a connection failure")
    func remoteFailureIsNotOurs() {
        #expect(SSHFailure.classify(status: 127, stderr: "bash: claude: command not found\n") == nil)
        #expect(SSHFailure.classify(status: 1, stderr: "fatal: not a git repository\n") == nil)
        #expect(SSHFailure.classify(status: 0, stderr: "") == nil)
    }

    @Test("anything unrecognised keeps its first line rather than being summarised")
    func unrecognised() {
        let failure = SSHFailure.classify(
            status: 255,
            stderr: "\nssh: something nobody has classified yet\nand a second line\n"
        )
        #expect(failure == .other("ssh: something nobody has classified yet"))
    }
}
