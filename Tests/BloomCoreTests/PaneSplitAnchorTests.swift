import Testing
@testable import BloomCore

@Suite("MCP split destinations")
struct PaneSplitAnchorTests {
    private let caller = SessionID("caller")
    private let other = SessionID("other")

    private func single(_ root: PaneContent) -> PaneSplitAnchor.Tab {
        .init(root: root, layout: SplitLayout(pane: root.id), contents: [root.id: root])
    }

    @Test("another selected tab cannot redirect a split away from the calling chat")
    func selectedElsewhere() throws {
        let chat = PaneContent.chat(caller)
        let terminal = PaneContent.tool("terminal")
        let destination = try #require(PaneSplitAnchor.chat(caller).resolve(
            in: [single(terminal), single(.chat(other)), single(chat)], selected: terminal
        ))
        #expect(destination.tab == chat)
        #expect(destination.pane == caller.rawValue)
    }

    @Test("an absorbed chat is split beside itself even when a neighbouring terminal has focus")
    func absorbedChat() throws {
        let root = PaneContent.chat(other)
        var layout = SplitLayout(pane: "other-pane")
        layout.split("other-pane", axis: .horizontal, into: "caller-pane")
        layout.split("caller-pane", axis: .vertical, into: "terminal-pane")
        let snapshot = PaneSplitAnchor.Tab(root: root, layout: layout, contents: [
            "other-pane": root, "caller-pane": .chat(caller), "terminal-pane": .tool("terminal"),
        ])
        let destination = try #require(PaneSplitAnchor.chat(caller).resolve(in: [snapshot], selected: root))
        #expect(destination.tab == root)
        #expect(destination.pane == "caller-pane")
        let split = layout.split(destination.pane, axis: .horizontal, into: "new-chat")
        #expect(split)
        #expect(layout.root == .split(axis: .horizontal, ratio: 0.5, first: .pane("other-pane"), second:
            .split(axis: .vertical, ratio: 0.5, first:
                .split(axis: .horizontal, ratio: 0.5, first: .pane("caller-pane"), second: .pane("new-chat")),
                second: .pane("terminal-pane"))))
    }

    @Test("a duplicated conversation prefers its focused copy")
    func duplicateChat() throws {
        let root = PaneContent.chat(caller)
        var layout = SplitLayout(pane: "first")
        layout.split("first", axis: .horizontal, into: "second")
        let snapshot = PaneSplitAnchor.Tab(root: root, layout: layout, contents: ["first": root, "second": root])
        let destination = try #require(PaneSplitAnchor.chat(caller).resolve(in: [snapshot], selected: root))
        #expect(destination.pane == "second")
    }

    @Test("a missing calling chat never falls back to the selected pane")
    func missingChat() {
        let root = PaneContent.chat(other)
        let destination = PaneSplitAnchor.chat(caller).resolve(in: [single(root)], selected: root)
        #expect(destination == nil)
    }

    @Test("an explicit active-pane request uses the selected tab's focused region")
    func explicitActivePane() throws {
        let root = PaneContent.chat(caller)
        var layout = SplitLayout(pane: "chat")
        layout.split("chat", axis: .horizontal, into: "terminal")
        let snapshot = PaneSplitAnchor.Tab(root: root, layout: layout, contents: ["chat": root, "terminal": .tool("shell")])
        let destination = try #require(PaneSplitAnchor.activePane.resolve(in: [snapshot], selected: root))
        #expect(destination.pane == "terminal")
        #expect(PaneSplitAnchor.activePane.resolve(in: [snapshot], selected: nil) == nil)
    }
}

@Suite("MCP split defaults", .tags(.persistence), .scratchDirectory)
struct PaneSplitDefaultsTests {
    private let identity = BridgeIdentity(sessionID: SessionID("caller"), workspaceID: WorkspaceID("workspace"), role: .parent)

    @Test("add a pane needs no arguments and opens a new chat to the caller's right")
    func defaults() async throws {
        let store = try makeTestStore("pane-defaults")
        let identity = identity
        let tool = PaneSplitTool { order, axis, anchor, workspaceID in
            #expect(order.kind == .chat)
            #expect(axis == .horizontal)
            #expect(anchor == .chat(SessionID("caller")))
            #expect(workspaceID == identity.workspaceID)
            return .opened("Split beside the caller")
        }
        #expect(tool.tool.inputSchema["required"] == .array([]))
        let result = await tool.call(MCPRequest(id: .integer(1), method: "pane_split"), as: identity, store: store)
        #expect(!result.isError)
        #expect(result.text == "Split beside the caller")
    }

    @Test("explicit kind, direction and active-pane target reach the app")
    func explicitArguments() async throws {
        let store = try makeTestStore("pane-explicit")
        let tool = PaneSplitTool { order, axis, anchor, _ in
            #expect(order.kind == .terminal)
            #expect(order.title == "Logs")
            #expect(axis == .vertical)
            #expect(anchor == .activePane)
            return .refused("The target disappeared")
        }
        let request = MCPRequest(id: .integer(1), method: "pane_split", params: .object([
            "kind": .string("terminal"), "title": .string("Logs"),
            "direction": .string("below"), "target": .string("active_pane"),
        ]))
        let result = await tool.call(request, as: identity, store: store)
        #expect(result.isError)
        #expect(result.text == "The target disappeared")
    }

    @Test("invalid targeting and non-string defaults cannot mutate the window")
    func invalidArguments() async throws {
        let store = try makeTestStore("pane-invalid")
        let tool = PaneSplitTool { _, _, _, _ in
            Issue.record("Invalid arguments reached the window")
            return .opened("Unexpected")
        }
        for arguments: [String: JSONValue] in [
            ["target": .string("another_chat")], ["target": .bool(true)],
            ["direction": .integer(1)], ["kind": .bool(false)], ["direction": .string("diagonal")],
        ] {
            let request = MCPRequest(id: .integer(1), method: "pane_split", params: .object(arguments))
            let result = await tool.call(request, as: identity, store: store)
            #expect(result.isError)
        }
    }
}
