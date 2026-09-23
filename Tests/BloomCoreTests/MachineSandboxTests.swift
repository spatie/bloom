import Testing
@testable import BloomCore

/// The command that runs an agent, a shell or a script as the user that cannot manage the machine.
@Suite("Running as the sandbox user")
struct MachineSandboxTests {
    let sandbox = MachineSandbox(user: "bloom-agent")

    @Test("the command masks the machine's socket, then drops to the sandbox user for good")
    func wrapping() {
        let wrapped = sandbox.wrap(executable: "/usr/local/lib/bloom-agents/claude/claude", arguments: ["-p", "say hi"])
        #expect(wrapped.executable == "/usr/bin/sudo")
        #expect(wrapped.arguments.dropLast() == ["-E", "/usr/bin/unshare", "--mount", "--propagation", "private", "--", "/bin/sh", "-c"])
        let script = try! #require(wrapped.arguments.last)
        #expect(script == "mount --bind /dev/null '/.sprite/api.sock' && exec '/usr/bin/setpriv' '--reuid=bloom-agent' "
            + "'--regid=bloom-agent' '--init-groups' '/usr/local/lib/bloom-agents/claude/claude' '-p' 'say hi'")
        // The keys a turn carries are in the environment, never in these arguments, which ps shows.
        #expect(!wrapped.arguments.contains { $0.contains("ANTHROPIC") })
    }

    @Test("the PATH it is given survives sudo, which would otherwise replace it")
    func path() throws {
        let wrapped = sandbox.wrap(executable: "/bin/sh", arguments: ["-c", "bun run dev"], path: "/home/sprite/.local/bin:/usr/bin")
        let script = try #require(wrapped.arguments.last)
        #expect(script.contains("&& export PATH='/home/sprite/.local/bin:/usr/bin' && exec '/usr/bin/setpriv'"))
    }

    @Test("an argument that tries to end the quoting cannot")
    func quoting() {
        let wrapped = sandbox.wrap(executable: "/bin/echo", arguments: ["'; rm -rf / #", "$(whoami)", "a b"])
        let script = try! #require(wrapped.arguments.last)
        #expect(script.contains(#"''\''; rm -rf / #'"#))
        #expect(script.contains("'$(whoami)'"))
        #expect(script.contains("'a b'"))
    }

    @Test("a sandboxed process gets its own home, so a CLI does not write into the Runner's")
    func environment() {
        let environment = sandbox.environment(["PATH": "/usr/bin", "HOME": "/home/sprite", "ANTHROPIC_API_KEY": "k"])
        #expect(environment["HOME"] == "/home/bloom-agent")
        #expect(environment["USER"] == "bloom-agent")
        #expect(environment["LOGNAME"] == "bloom-agent")
        #expect(environment["ANTHROPIC_API_KEY"] == "k", "what the turn needs still travels")
    }

    /// Every agent CLI is spawned through an `AgentLaunch`, which is why one wrapping covers all of
    /// them, and why the working directory survives it: the sandbox user works in the same worktree.
    @Test("a launch keeps its directory and gains the sandbox user's home")
    func wrappingALaunch() {
        let launch = AgentLaunch(executable: "/usr/local/bin/claude", arguments: ["--print"],
                                 cwd: "/home/sprite/workspace", environment: ["HOME": "/home/sprite", "ANTHROPIC_API_KEY": "k"])
        let wrapped = sandbox.wrap(launch)
        #expect(wrapped.executable == "/usr/bin/sudo")
        #expect(wrapped.cwd == "/home/sprite/workspace")
        #expect(wrapped.environment["HOME"] == "/home/bloom-agent")
        #expect(wrapped.environment["ANTHROPIC_API_KEY"] == "k")
        #expect(wrapped.arguments.last?.contains("'/usr/local/bin/claude' '--print'") == true)
    }

    /// Availability is false where the sandbox account or either required tool is missing.
    @Test("nothing is wrapped where the user or the tools are missing")
    func availability() {
        #expect(MachineSandbox.available(hasUser: { _ in false }, isExecutable: { _ in true }) == nil)
        #expect(MachineSandbox.available(hasUser: { _ in true }, isExecutable: { $0 != "/usr/bin/setpriv" }) == nil)
        let found = MachineSandbox.available(hasUser: { $0 == "bloom-agent" }, isExecutable: { _ in true })
        #expect(found?.user == "bloom-agent")
        #expect(found?.home == "/home/bloom-agent")
        #expect(MachineSandbox.userExists("nobody-called-this") == false)
    }
}
