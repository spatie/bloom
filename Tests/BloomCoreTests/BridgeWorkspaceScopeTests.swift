import Testing
@testable import BloomCore

/// The gate and the refusal that every tool scoped to the caller's own workspace shares.
///
/// Both were written out per tool before they were written down once: the role gate as the same
/// paragraph pasted into four files, the refusal as one fact said thirteen times in eight
/// spellings. What these tests hold is the property that made collapsing them worth doing. Every
/// tool on the gate answers the same way, and a role widened on one of them is widened on all of
/// them or on none.
@Suite("Bridge workspace scope")
struct BridgeWorkspaceScopeTests {
    /// The sentence, and the half of it that has to stay the tool's own: a refusal that names the
    /// tool and what it would have done is one a model can act on.
    @Test("the refusal names the tool, what it would have done, and what is missing")
    func theRefusalIsOneSentence() {
        #expect(
            BridgeWorkspaceScope.refusal(tool: "pane_open", doing: "opens a pane in")
                == "pane_open opens a pane in the workspace you are in, and this connection is "
                + "not speaking for one."
        )
        #expect(
            BridgeWorkspaceScope.refusal(tool: "workspace_rename", doing: "renames")
                == "workspace_rename renames the workspace you are in, and this connection is not "
                + "speaking for one."
        )
    }

    /// The two refusal sets that carry this fact inside a `Trouble` enum rather than at the call
    /// site reach it through the same function, so all three doors say one thing. A model told two
    /// different things about one absence learns that one of them is wrong.
    @Test("the trouble enums say it the same way the tools do")
    func theTroubleEnumsAgree() {
        #expect(
            CrewToolTrouble.notInAWorkspace(tool: "agent_list").sentence
                == BridgeWorkspaceScope.refusal(
                    tool: "agent_list", doing: "is about the agents working in"
                )
        )
        #expect(
            WorkspaceRenameTrouble.notInAWorkspace.sentence
                == BridgeWorkspaceScope.refusal(tool: "workspace_rename", doing: "renames")
        )
    }

    /// **`.owner` must not be on this gate**, which is the mistake the shared constant exists to
    /// stop being made a seventh time: `BridgeIdentity.owner` carries no workspace, so a tool
    /// advertised to it here could only ever answer with the refusal above. `.child` is off it
    /// because a subagent moving the reader's panes is something happening to them on behalf of a
    /// thing they did not address.
    @Test("only a parent is on the workspace-scoped gate")
    func onlyAParentIsOnTheGate() {
        #expect(BridgeWorkspaceScope.roles == [.parent])
    }

    /// Every tool that refuses a connection with no workspace is gated the same way, asked of the
    /// listing rather than of the constant: a role that can see a tool it can only ever be refused
    /// is a tool advertised to a caller it can never serve, which is exactly what four of these
    /// were when they were gated one at a time.
    @Test("every workspace-scoped tool is listed to a parent and to nobody else")
    func theGateIsOnAllOfThem() {
        let handlers: [any BridgeToolHandling] = [
            PaneOpenTool { _, _ in .opened("") },
            PaneSplitTool { _, _, _ in .opened("") },
            PaneCloseTool { _, _ in .opened("") },
            PaneRenameTool { _, _, _ in .opened("") },
            PaneListTool { _ in nil },
            WorkspaceTabsTool { _ in nil },
            WorkspaceTabSelectTool { _, _ in .refused("") },
            MediaShowTool { _, _ in .refused("") },
            TerminalStartTool { _, _ in .opened("") },
            TerminalReadTool { _, _ in .refused("") },
            TerminalWriteTool { _, _ in .refused("") },
            TerminalSendKeyTool { _, _ in .refused("") },
            BrowserReadTool { _, _ in .refused("") },
            BrowserReloadTool { _, _ in .refused("") },
            BrowserGoTool { _, _ in .refused("") },
            BrowserScreenshotTool { _, _ in .refused("") },
            BrowserScrollTool { _, _ in .refused("") },
            BrowserTextTool { _, _ in .refused("") },
        ]
        let toolbox = BridgeToolbox(handlers: handlers)
        #expect(toolbox.tools(for: .parent).count == handlers.count)
        #expect(toolbox.tools(for: .child).isEmpty)
        #expect(toolbox.tools(for: .owner).isEmpty)
    }
}
