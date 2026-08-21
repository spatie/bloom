import Foundation
import Testing
@testable import BloomCore

@Suite("BridgeSocketPath")
struct BridgeSocketPathTests {
    @Test("names the socket from the same fingerprint the tmux socket uses")
    func sharesTheFingerprint() throws {
        let database = "/Users/someone/Library/Application Support/Bloom/bloom.sqlite"
        let path = try BridgeSocketPath.derive(databasePath: database, directory: "/tmp")
        let fingerprint = TmuxSessions.fingerprint(database)

        #expect(path == "/tmp/bloom-bridge-\(fingerprint).sock")
        // The whole point of deriving it: two instances, two sockets. `Tools/guard.sh` mirrors
        // this same fingerprint in Python, so a divergence here stops the guard protecting the
        // right instance.
        let dev = try BridgeSocketPath.derive(
            databasePath: "/Users/someone/Library/Application Support/Bloom Dev/bloom.sqlite",
            directory: "/tmp"
        )
        #expect(dev != path)
    }

    @Test("refuses a path sun_path would truncate rather than binding a shorter one")
    func refusesALongPath() throws {
        let directory = "/" + String(repeating: "d", count: 120)
        #expect(throws: BridgeSocketPathError.self) {
            try BridgeSocketPath.derive(databasePath: "/db.sqlite", directory: directory)
        }
    }

    @Test("fits under the limit in the per-user temporary directory")
    func fitsInTheRealPlace() throws {
        let path = try BridgeSocketPath.derive(databasePath: "/Users/someone/Library/Application Support/Bloom/bloom.sqlite")
        #expect(path.utf8.count < BridgeSocketPath.limit)
    }
}

@Suite("BridgeRegistry")
struct BridgeRegistryTests {
    @Test("a token resolves to the session and workspace it was minted for")
    func resolves() {
        let registry = BridgeRegistry()
        let session = SessionID("s1")
        let workspace = WorkspaceID("w1")
        let token = registry.mint(sessionID: session, workspaceID: workspace, role: .child)

        let identity = registry.identity(forToken: token)
        #expect(identity?.sessionID == session)
        #expect(identity?.workspaceID == workspace)
        #expect(identity?.role == .child)
        #expect(registry.identity(forToken: "something else") == nil)
    }

    @Test("re-minting retires the token it replaces")
    func reminting() {
        let registry = BridgeRegistry()
        let session = SessionID("s1")
        let first = registry.mint(sessionID: session, workspaceID: WorkspaceID("w1"), role: .parent)
        let second = registry.mint(sessionID: session, workspaceID: WorkspaceID("w1"), role: .parent)

        #expect(first != second)
        #expect(registry.identity(forToken: first) == nil)
        #expect(registry.identity(forToken: second) != nil)
        #expect(registry.count == 1)
    }

    @Test("a role is read off the workspace, not off what a caller says")
    func roleComesFromParentage() {
        #expect(BridgeRole(origin: .user) == .parent)
        #expect(BridgeRole(origin: .agent(parentWorkspaceID: WorkspaceID("p"), spawnToolUseID: "t")) == .child)
    }
}

@Suite("BridgeRegistration", .tags(.security), .scratchDirectory)
struct BridgeRegistrationTests {
    private let attachment = BridgeAttachment(
        shimPath: "/Applications/Bloom.app/Contents/MacOS/bloom-bridge",
        socketPath: "/var/folders/xx/T/bloom-bridge-1a2b3c4d.sock",
        token: "t0ken",
        role: .child
    )

    /// The finding this test exists for, measured on codex-cli 0.147.0: a `-c` override of
    /// `mcp_servers.bloom` against a user's own entry of that name does NOT shadow it. `command`
    /// was replaced, the user's `args` survived, and `env` merged key by key so the user's
    /// variable was still there. `codex mcp list` reported the chimera as one healthy server with
    /// no warning. There is no `-c` form that replaces a whole entry, including overriding the
    /// entire inline table, so a distinctive name is the only defence there is.
    @Test("the server name is one nobody would type by hand")
    func theNameIsCollisionProof() {
        #expect(BridgeRegistration.serverName == "bloom-workspace-bridge")
        #expect(BridgeRegistration.serverName != "bloom")
        #expect(BridgeRegistration.serverName.contains("bloom"))
    }

    @Test("the Claude config names the shim, its environment and no arguments")
    func claudeConfigShape() throws {
        let data = try BridgeRegistration.claudeConfig(attachment)
        let document = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try #require(document["mcpServers"] as? [String: Any])
        #expect(Array(servers.keys) == [BridgeRegistration.serverName])

        let server = try #require(servers[BridgeRegistration.serverName] as? [String: Any])
        #expect(server["command"] as? String == attachment.shimPath)
        #expect((server["args"] as? [String])?.isEmpty == true)

        let environment = try #require(server["env"] as? [String: String])
        #expect(environment[BridgeProtocol.socketVariable] == attachment.socketPath)
        #expect(environment[BridgeProtocol.tokenVariable] == attachment.token)
        #expect(environment[BridgeProtocol.roleVariable] == "child")
    }

    @Test("the config file is written where only its owner can read it")
    func claudeConfigIsPrivate() throws {
        let directory = TestScratch.unique("bridge-config")
        let path = try BridgeRegistration.writeClaudeConfig(
            attachment,
            sessionID: SessionID("abc"),
            directory: directory
        )
        #expect(path.hasSuffix("abc.mcp.json"))

        let mode = try #require(
            FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        )
        #expect(mode.int16Value == 0o600)
    }

    @Test("the Codex overrides carry the command, empty arguments and the environment")
    func codexArgumentShape() throws {
        let arguments = BridgeRegistration.codexArguments(attachment)
        let name = BridgeRegistration.serverName

        #expect(arguments.filter { $0 == "-c" }.count == 3)
        #expect(arguments.contains("mcp_servers.\(name).command=\"\(attachment.shimPath)\""))
        // Stated rather than left out. An override that names nothing leaves the colliding entry's
        // value in place, and the whole reason the name is distinctive is that there should be no
        // colliding entry to inherit from.
        #expect(arguments.contains("mcp_servers.\(name).args=[]"))
        let environment = try #require(arguments.first { $0.hasPrefix("mcp_servers.\(name).env=") })
        #expect(environment.contains("\(BridgeProtocol.tokenVariable)=\"t0ken\""))
        #expect(environment.contains("\(BridgeProtocol.socketVariable)=\"\(attachment.socketPath)\""))
        #expect(environment.hasSuffix("}"))
    }

    @Test("a value with a quote in it cannot close the TOML string early")
    func codexQuotingHolds() {
        let hostile = BridgeAttachment(
            shimPath: #"/tmp/a"b\c"#,
            socketPath: "/tmp/s.sock",
            token: "t",
            role: .parent
        )
        let arguments = BridgeRegistration.codexArguments(hostile)
        let command = arguments.first { $0.contains(".command=") }
        #expect(command?.hasSuffix(#"command="/tmp/a\"b\\c""#) == true)
    }
}

@Suite("BridgeHandshake")
struct BridgeHandshakeTests {
    @Test("a matching version is accepted")
    func matching() {
        let hello = BridgeHello(token: "t", role: "parent", shim: "/tmp/bloom-bridge")
        #expect(BridgeProtocol.problem(with: hello) == nil)
    }

    /// The failure to design for is Sparkle swapping the bundle underneath a running app: a new
    /// shim meets an older Bloom, or an old per-session config names a binary that has been
    /// replaced. Compared for equality, and the sentence has to name both numbers and the actual
    /// remedy, because a hanging tool call is a hung turn.
    @Test("a mismatched version is refused in a sentence naming both numbers")
    func mismatched() throws {
        let hello = BridgeHello(
            version: BridgeProtocol.version + 1,
            token: "t",
            role: "parent",
            shim: "/tmp/bloom-bridge"
        )
        let problem = try #require(BridgeProtocol.problem(with: hello))
        #expect(problem.contains("\(BridgeProtocol.version)"))
        #expect(problem.contains("\(BridgeProtocol.version + 1)"))
        #expect(problem.lowercased().contains("quit and reopen bloom"))
    }

    @Test("a welcome round trips as JSON")
    func welcomeEncoding() throws {
        let welcome = BridgeWelcome.refusing("no")
        let data = try JSONEncoder().encode(welcome)
        #expect(try JSONDecoder().decode(BridgeWelcome.self, from: data) == welcome)
    }
}
