import Testing
import Foundation
@testable import BloomCore

/// The argv handed to `/usr/bin/ssh`, asserted on without a process ever existing.
///
/// This is `AgentLaunch`'s trick applied to the connection: everything about how Bloom talks to a
/// server is a value, so the options that make the whole design work can be pinned rather than
/// hoped for. Every one of them has been deleted by somebody at some point.
@Suite("SSH invocation")
struct SSHInvocationTests {
    private func invocation(
        _ text: String,
        controlDirectory: String = "/Users/someone/.bloom/ssh"
    ) throws -> SSHInvocation {
        SSHInvocation(
            destination: try SSHDestination.parse(text),
            controlDirectory: controlDirectory
        )
    }

    @Test("the connection options are all there")
    func options() throws {
        let argv = try invocation("deploy@vps.example.com").options

        // Pairs, so an option and its value cannot drift apart in the list.
        var pairs: [String] = []
        for index in stride(from: 0, to: argv.count - 1, by: 2) {
            #expect(argv[index] == "-o")
            pairs.append(argv[index + 1])
        }

        #expect(pairs.contains("BatchMode=yes"))
        #expect(pairs.contains("ConnectTimeout=8"))
        #expect(pairs.contains("ControlMaster=auto"))
        #expect(pairs.contains("ControlPath=/Users/someone/.bloom/ssh/%C"))
        #expect(pairs.contains("ControlPersist=120"))
        #expect(pairs.contains("ServerAliveInterval=15"))
        #expect(pairs.contains("ServerAliveCountMax=3"))
    }

    /// **Never.** Passing either would make Bloom accept a key nobody has looked at, on the user's
    /// behalf, which removes the only defence there is against a machine in the middle. Whatever
    /// the user's own config says is what happens; Bloom does not get a vote.
    @Test("host key checking is never weakened", .tags(.security))
    func neverWeakensHostKeyChecking() throws {
        let argv = try invocation("deploy@vps.example.com").arguments(
            for: CommandLaunch(executable: "true", timeout: .seconds(5))
        )
        #expect(!argv.contains { $0.contains("StrictHostKeyChecking") })
        #expect(!argv.contains { $0.contains("UserKnownHostsFile") })
        // And nothing that would point ssh at a key, or away from the user's agent.
        #expect(!argv.contains("-i"))
        #expect(!argv.contains { $0.contains("IdentityFile") })
    }

    /// A unix socket path is capped at 104 bytes on macOS, and `ssh` refuses outright rather than
    /// falling back: measured, `ControlPath too long ('...' >= 104 bytes)`, exit 1. `%C` is a
    /// forty character SHA1 whatever the host is called, which is what keeps the total inside the
    /// budget for any plausible home directory.
    @Test("the control socket path stays under the 104 byte cap")
    func controlPathFitsInSunPath() throws {
        let longHost = String(repeating: "a", count: 60) + ".example.com"
        let expanded = try invocation("someverylongusername@\(longHost)")
            .controlPath
            .replacingOccurrences(of: "%C", with: String(repeating: "0", count: 40))
        #expect(expanded.utf8.count < 104)

        // And the real default directory on this machine, which is the one that actually ships.
        let real = SSHInvocation.defaultControlDirectory + "/" + String(repeating: "0", count: 40)
        #expect(real.utf8.count < 104)
    }

    /// `ssh` joins everything after the destination with single spaces and hands the result to the
    /// remote login shell, which splits it again. A worktree cut from a workspace called "fix the
    /// login page" is a path with spaces in it, and unquoted it arrives as four arguments.
    @Test("every remote word is quoted exactly once", .tags(.security))
    func remoteWordsAreQuoted() throws {
        let argv = try invocation("deploy@vps").arguments(for: CommandLaunch(
            executable: "python3",
            arguments: ["/home/deploy/.bloom/bin/bloomd", "status", "/srv/fix the login page"],
            timeout: .seconds(5)
        ))

        let tail = Array(argv.suffix(4))
        #expect(tail == [
            "'python3'",
            "'/home/deploy/.bloom/bin/bloomd'",
            "'status'",
            "'/srv/fix the login page'",
        ])
    }

    /// Both of these were sent through a real `ssh` to a real server and came back as the exact
    /// directories they name, which is the only way to be sure about a quoting rule: the far end
    /// is somebody else's shell.
    @Test("a single quote in a path cannot end the quoting", .tags(.security))
    func quoteInsideAWord() {
        #expect(SSHInvocation.singleQuoted("/srv/it's here") == #"'/srv/it'\''s here'"#)
        #expect(SSHInvocation.singleQuoted("/root/it's $weird") == #"'/root/it'\''s $weird'"#)
        // Every one of these is inert inside single quotes, which is the reason single quotes
        // were chosen over backslashes or double quotes.
        #expect(SSHInvocation.singleQuoted("$(id)") == "'$(id)'")
        #expect(SSHInvocation.singleQuoted("`id`") == "'`id`'")
        #expect(SSHInvocation.singleQuoted("a\nb") == "'a\nb'")
        #expect(SSHInvocation.singleQuoted("") == "''")
    }

    /// Verified against OpenSSH 10.3 rather than assumed: `ssh` parses with `getopt`, which stops
    /// at `--`, so the destination cannot be read as an option even if one got past parsing.
    @Test("the destination comes after a bare --")
    func endOfOptions() throws {
        let argv = try invocation("deploy@vps").arguments(
            for: CommandLaunch(executable: "true", timeout: .seconds(5))
        )
        let separator = try #require(argv.firstIndex(of: "--"))
        #expect(argv[separator + 1] == "deploy@vps")
    }

    @Test("a port becomes -p and never rides on the destination")
    func portBecomesAFlag() throws {
        let argv = try invocation("deploy@vps:2222").arguments(
            for: CommandLaunch(executable: "true", timeout: .seconds(5))
        )
        let flag = try #require(argv.firstIndex(of: "-p"))
        #expect(argv[flag + 1] == "2222")
        #expect(argv.contains("deploy@vps"))
        #expect(!argv.contains("deploy@vps:2222"))
    }

    /// A destination with no port must not carry one, or a `Port` in the user's own `Host` block
    /// would be overridden by a default nobody typed.
    @Test("no port means no -p at all")
    func noPortNoFlag() throws {
        let argv = try invocation("deploy@vps").arguments(
            for: CommandLaunch(executable: "true", timeout: .seconds(5))
        )
        #expect(!argv.contains("-p"))
    }

    /// See the comment on `maxConcurrentChannels`. `sshd`'s `MaxSessions` is 10 by default and the
    /// eleventh channel does not fail, it silently opens its own connection.
    @Test("the channel ceiling stays under sshd's default MaxSessions")
    func channelCeiling() {
        #expect(SSHInvocation.maxConcurrentChannels < 10)
    }
}
