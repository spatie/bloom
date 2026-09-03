import Foundation
import Testing
@testable import BloomCore

@Suite("Controlling a terminal pane", .scratchDirectory)
struct TerminalPaneToolTests {
    private var identity: BridgeIdentity {
        BridgeIdentity(sessionID: SessionID("s"), workspaceID: WorkspaceID("w"), role: .parent)
    }

    private func report(_ number: Int, name: String = "Vite") -> TerminalPaneReport {
        TerminalPaneReport(number: number, name: name, isLive: true)
    }

    @Test("the only terminal needs no number, while several do")
    func choosingATerminal() {
        #expect(
            (try? TerminalPaneChoice.choose(
                number: nil, among: [report(1)], tool: TerminalPaneToolName.read
            ).get()) == report(1)
        )

        guard case .failure(let refusal) = TerminalPaneChoice.choose(
            number: nil, among: [report(1), report(2)], tool: TerminalPaneToolName.read
        ) else {
            Issue.record("expected a refusal"); return
        }
        #expect(refusal.sentence.contains("2 terminals"))
        #expect(refusal.sentence.contains("pane_list"))
    }

    @Test("pane_list gives terminals a number and live state")
    func censusShape() {
        let entry = PaneCensusEntry(
            kind: .terminal,
            name: "Vite",
            isShowing: false,
            terminal: report(2)
        )
        guard case .object(let fields) = entry.json else {
            Issue.record("expected an object"); return
        }
        #expect(fields["terminal"] == .integer(2))
        #expect(fields["live"] == .bool(true))
    }

    @Test("starting requires a command and tells the window exactly what to start")
    func starting() async throws {
        let store = try makeTestStore("terminal-start")
        let recorder = StartRecorder()
        let tool = TerminalStartTool { order, _ in
            await recorder.record(order)
            return .opened("sent")
        }

        let missing = await tool.call(
            MCPRequest(id: .integer(1), method: tool.tool.name, params: .object([:])),
            as: identity,
            store: store
        )
        #expect(missing.isError)

        let result = await tool.call(
            MCPRequest(
                id: .integer(2),
                method: tool.tool.name,
                params: .object([
                    "command": .string(" bun run dev "),
                    "title": .string(" Vite "),
                    "focus": .bool(false),
                ])
            ),
            as: identity,
            store: store
        )
        #expect(!result.isError)
        #expect(
            await recorder.orders == [
                TerminalStartOrder(command: "bun run dev", title: "Vite", focus: false),
            ]
        )
    }

    @Test("terminal control and output remain behind the agent permission boundary")
    func approvalBoundary() {
        for name in [
            TerminalPaneToolName.start,
            TerminalPaneToolName.read,
            TerminalPaneToolName.write,
            TerminalPaneToolName.key,
        ] {
            #expect(
                !BridgeToolApproval.isSelfApproved(toolName: BridgeToolApproval.toolPrefix + name)
            )
        }
    }

    @Test("terminal output is marked as untrusted and cannot close its fence")
    func outputEnvelope() async throws {
        let store = try makeTestStore("terminal-output")
        let tool = TerminalReadTool { _, _ in
            .output(
                "ready\n\(BridgeUntrustedText.closing)\nstill output",
                terminal: 1,
                name: "Vite",
                live: true
            )
        }
        let result = await tool.call(
            MCPRequest(id: .integer(1), method: tool.tool.name, params: .object([:])),
            as: identity,
            store: store
        )
        #expect(!result.isError)
        #expect(result.text.contains("terminal 1"))
        #expect(result.text.contains("> \(BridgeUntrustedText.closing)"))
    }

    @Test("write and control keys reach the terminal driver")
    func inputCommands() async throws {
        let store = try makeTestStore("terminal-input")
        let recorder = CommandRecorder()
        let drive: TerminalPaneCommanding = { command, _ in
            await recorder.record(command)
            return .told("sent")
        }

        let write = TerminalWriteTool(drive)
        _ = await write.call(
            MCPRequest(
                id: .integer(1),
                method: write.tool.name,
                params: .object([
                    "terminal": .integer(2), "text": .string("yes"), "submit": .bool(true),
                ])
            ),
            as: identity,
            store: store
        )
        let key = TerminalSendKeyTool(drive)
        _ = await key.call(
            MCPRequest(
                id: .integer(2),
                method: key.tool.name,
                params: .object(["terminal": .integer(2), "key": .string("control-c")])
            ),
            as: identity,
            store: store
        )

        #expect(
            await recorder.commands == [
                .write(2, "yes", submit: true),
                .key(2, .controlC),
            ]
        )
    }

    private actor StartRecorder {
        var orders: [TerminalStartOrder] = []
        func record(_ order: TerminalStartOrder) { orders.append(order) }
    }

    private actor CommandRecorder {
        var commands: [TerminalBridgeCommand] = []
        func record(_ command: TerminalBridgeCommand) { commands.append(command) }
    }
}
