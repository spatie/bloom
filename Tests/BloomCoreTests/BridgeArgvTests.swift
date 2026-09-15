import Foundation
import Testing
@testable import BloomCore

/// The two argv builders, which is where a registration either reaches the CLI or does not.
///
/// Kept apart from the config and override builders because this is the other half of the same
/// decision: what Bloom writes, and what Bloom then tells the CLI to read.
@Suite("BridgeArgv", .tags(.security))
struct BridgeArgvTests {
    private let session = Session(workspaceID: WorkspaceID("w"), model: "opus")

    @Test("Claude Code is pointed at the config file and never told to ignore the user's servers")
    func claudeArgv() throws {
        let arguments = AgentRunner.argv(
            session: session,
            resume: nil,
            mcpConfigPath: "/tmp/bridge/s.mcp.json"
        )
        let flag = try #require(arguments.firstIndex(of: "--mcp-config"))
        #expect(arguments[flag + 1] == "/tmp/bridge/s.mcp.json")
        // `--strict-mcp-config` would shut every MCP server the user configured out of their own
        // chat. `WorkspaceNamer` passes it deliberately, for a call that must see nothing; a chat
        // is the opposite case.
        #expect(!arguments.contains("--strict-mcp-config"))
    }

    @Test("no config, no flag")
    func claudeArgvWithoutABridge() {
        #expect(!AgentRunner.argv(session: session, resume: nil).contains("--mcp-config"))
    }

    @Test("Codex is given the overrides after app-server and never --strict-config")
    func codexArgv() {
        let attachment = BridgeAttachment(
            shimPath: "/tmp/bloom-bridge",
            socketPath: "/tmp/s.sock",
            token: "t",
            role: .parent
        )
        let launch = CodexClient.launch(CodexClient.Configuration(
            cwd: "/tmp/w",
            environment: [:],
            bridge: attachment
        ))
        #expect(launch.arguments.starts(with: ["app-server", "--listen", "stdio://"]))
        #expect(launch.arguments.contains("-c"))
        #expect(launch.arguments.contains { $0.hasPrefix("mcp_servers.\(BridgeRegistration.serverName).command=") })
        // The same trap under a different name: it makes Codex refuse to start on a user config
        // holding anything this build does not recognise.
        #expect(!launch.arguments.contains("--strict-config"))
    }

    @Test("no attachment, no overrides")
    func codexArgvWithoutABridge() {
        let launch = CodexClient.launch(CodexClient.Configuration(cwd: "/tmp/w", environment: [:]))
        #expect(launch.arguments == CodexClient.arguments)
    }

    @Test("Grok is launched as ACP stdio without attaching to the user's leader")
    func grokArgv() {
        let attachment = BridgeAttachment(
            shimPath: "/tmp/bloom-bridge",
            socketPath: "/tmp/s.sock",
            token: "t",
            role: .parent
        )
        let launch = GrokClient.launch(GrokClient.Configuration(
            cwd: "/tmp/w",
            environment: [:],
            model: "grok-4.6",
            effort: "high"
        ))
        #expect(launch.arguments.contains("agent"))
        #expect(launch.arguments.contains("--no-leader"))
        #expect(launch.arguments.contains("stdio"))
        #expect(launch.arguments.contains("--model"))
        #expect(launch.arguments.contains("grok-4.6"))
        #expect(launch.environment["GROK_DISABLE_AUTOUPDATER"] == "1")
        let servers = BridgeRegistration.grokServers(attachment)
        #expect(servers.count == 1)
        #expect(servers[0]["name"]?.stringValue == BridgeRegistration.serverName)
        #expect(servers[0]["command"]?.stringValue == "/tmp/bloom-bridge")
    }

    @Test("no Grok attachment, no MCP servers")
    func grokArgvWithoutABridge() {
        #expect(BridgeRegistration.grokServers(nil).isEmpty)
    }
}
