import Foundation

/// Every tool the bridge serves, and the only place a new one is added.
///
/// A list of handlers rather than a switch, because the phases after this one add five more tools
/// (`workspace_spawn`, `workspace_send`, `workspace_status`, `workspace_read`,
/// `workspace_report`, `workspace_archive`) and a switch would put each of them in three places:
/// the listing, the dispatch and the role gate. Here a tool is one type, and it carries its own
/// gate.
public struct BridgeToolbox: Sendable {
    public let handlers: [any BridgeToolHandling]

    public init(handlers: [any BridgeToolHandling]) {
        self.handlers = handlers
    }

    /// What phase one ships. `whoami` alone: it needs no runner, no writes and no parentage, so it
    /// proves the transport and the identity mapping without any of the machinery the tools that
    /// follow will need.
    ///
    /// One thing the live run measured that the tools after this one have to answer: **a bridge
    /// call raises a permission question like any other tool call.** On claude 2.1.238, under
    /// `acceptEdits`, calling `whoami` produced an ask for `mcp__bloom-workspace-bridge__whoami`
    /// and the turn stopped until it was answered. That matters because the reason the bridge is
    /// MCP rather than a CLI the agent shells out to was partly that a shell command goes through
    /// the permission machinery; being an MCP tool does not exempt it. A child that has to file
    /// `workspace_report` unattended therefore needs an answer of its own, either a grant Bloom
    /// makes for its own tools or an allow rule in the child's settings. See `LiveBridgeTests`.
    /// Everything that needs no seam back into the app. `workspace_start` is the exception and is
    /// added by `AppModel`, because starting a workspace has to reach the main-actor graph that
    /// runs one; see `WorkspaceStarting`. So this is what a `BridgeServer` built without the app
    /// serves, which is every test that did not ask for more.
    public static let standard = BridgeToolbox(handlers: [
        WhoamiTool(),
        ProjectListTool(),
        ProjectAddTool(),
        ProjectHideTool(),
        ProjectUnhideTool(),
    ])

    /// The tools a caller may see. Sorted by name so `tools/list` is stable between calls, which
    /// is one fewer thing to wonder about when a transcript is read back.
    public func tools(for role: BridgeRole) -> [BridgeTool] {
        handlers.filter { $0.roles.contains(role) }.map(\.tool).sorted { $0.name < $1.name }
    }

    /// The handler for a call, or nil when there is none this caller may reach. A tool that exists
    /// but is refused to this role answers nil exactly as an unknown name does, so the refusal
    /// cannot be read as a hint that something is there.
    public func handler(named name: String, for role: BridgeRole) -> (any BridgeToolHandling)? {
        handlers.first { $0.tool.name == name && $0.roles.contains(role) }
    }
}
