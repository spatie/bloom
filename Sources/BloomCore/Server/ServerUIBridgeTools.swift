import Foundation
import BloomClient

/// Existing MCP handlers retain schema, argument parsing, role gates and output bounds. Only
/// their UI seams cross the lease broker, after the server has validated the call.
enum ServerUIBridgeTools {
    static func handlers(broker: ServerUIBroker, store: Store) -> [any BridgeToolHandling] {
        let browser: BrowserPaneCommanding = { command, workspaceID in
            var arguments: [String: JSONValue] = ["browser": command.number.map(JSONValue.integer) ?? .null]
            switch command {
            case .go(_, let url): arguments["url"] = .string(url)
            case .scroll(_, let scroll):
                arguments["direction"] = .string(scroll.direction.rawValue)
                if scroll.direction == .up || scroll.direction == .down { arguments["pages"] = .number(Double(scroll.percent) / 100) }
            default: break
            }
            let result = await broker.perform(.init(name: command.toolName, arguments: .object(arguments)), workspaceID: workspaceID)
            if result.isError { return .refused(result.text) }
            if let png = result.png { return .pictured(png, result.text) }
            if let value = result.value { return .reported(value) }
            return .told(result.text)
        }
        let terminal: TerminalPaneCommanding = { command, workspaceID in
            var args: [String: JSONValue] = ["terminal": command.number.map(JSONValue.integer) ?? .null]
            switch command {
            case .read(_, let lines): args["lines"] = .integer(lines)
            case .write(_, let text, let submit): args["text"] = .string(text); args["submit"] = .bool(submit)
            case .key(_, let key): args["key"] = .string(key.rawValue)
            }
            let result = await broker.perform(.init(name: command.toolName, arguments: .object(args)), workspaceID: workspaceID)
            if result.isError { return .refused(result.text) }
            if case .read = command, let value = result.value,
               let text = value["text"]?.stringValue, let number = value["terminal"]?.intValue,
               let name = value["name"]?.stringValue, let live = value["live"]?.boolValue {
                return .output(text, terminal: number, name: name, live: live)
            }
            return .told(result.text)
        }
        return [
            TerminalStartTool { order, workspaceID in
                await pane(broker, name: "terminal_start", arguments: [
                    "command": .string(order.command), "title": order.title.map(JSONValue.string) ?? .null, "focus": .bool(order.focus),
                ], workspaceID: workspaceID)
            },
            TerminalReadTool(terminal), TerminalWriteTool(terminal), TerminalSendKeyTool(terminal),
            PaneOpenTool { order, workspaceID in
                await pane(broker, name: "pane_open", arguments: arguments(order), workspaceID: workspaceID)
            },
            PaneSplitTool { order, axis, anchor, workspaceID in
                var args = arguments(order); args["direction"] = .string(axis == .horizontal ? "beside" : "below")
                switch anchor {
                case .activePane: args["target"] = .string("active_pane")
                case .chat(let sessionID):
                    args["target"] = .string("this_chat")
                    args["sessionID"] = .string(sessionID.rawValue)
                }
                return await pane(broker, name: "pane_split_anchored", arguments: args, workspaceID: workspaceID)
            },
            PaneCloseTool { kind, workspaceID in
                await pane(broker, name: "pane_close", arguments: ["kind": kind.map { .string($0.rawValue) } ?? .null], workspaceID: workspaceID)
            },
            PaneRenameTool { title, kind, workspaceID in
                await pane(broker, name: "pane_rename", arguments: ["title": .string(title), "kind": kind.map { .string($0.rawValue) } ?? .null], workspaceID: workspaceID)
            },
            PaneListTool(report: { workspaceID in
                output(await broker.perform(.init(name: "pane_list"), workspaceID: workspaceID))
            }),
            WorkspaceTabsTool(report: { workspaceID in
                output(await broker.perform(.init(name: "workspace_tabs"), workspaceID: workspaceID))
            }),
            WorkspaceTabSelectTool { choice, workspaceID in
                let args: [String: JSONValue]
                switch choice {
                case .number(let number): args = ["tab": .integer(number)]
                case .title(let title): args = ["title": .string(title)]
                }
                let result = await broker.perform(.init(name: "workspace_tab_select", arguments: .object(args)), workspaceID: workspaceID)
                return result.isError ? .refused(result.text) : .selected(result.text)
            },
            BrowserReadTool(browser), BrowserReloadTool(browser), BrowserGoTool(browser),
            BrowserScreenshotTool(browser), BrowserScrollTool(browser), BrowserTextTool(browser),
            MediaShowTool { order, workspaceID in
                guard let workspace = try? await store.workspace(id: workspaceID), workspace.state != .archived,
                      let media = containedMedia(path: order.path, workspace: workspace) else {
                    return .refused("That is not an image or video inside this workspace. Save it in the workspace before calling media_show.")
                }
                let result = await broker.perform(.init(name: "media_show", arguments: .object([
                    "path": .string(media.relativePath), "caption": .string(order.caption),
                ])), workspaceID: workspaceID)
                return result.isError ? .refused(result.text) : .shown(result.text)
            },
        ]
    }

    /// Remote media is downloaded through the workspace-confined file API. The local viewer
    /// also accepts temp files, so never confuse its display basename with a contained path.
    static func containedMedia(path: String, workspace: Workspace) -> WorkspaceMedia? {
        guard let media = WorkspaceMedia.resolve(path: path, in: workspace.path),
              let contained = try? ServerFileOperations.contained(media.relativePath, workspace: workspace),
              contained.resolvingSymlinksInPath().standardizedFileURL == media.url else { return nil }
        return media
    }

    private static func arguments(_ order: PaneOrder) -> [String: JSONValue] {
        ["kind": .string(order.kind.rawValue), "url": order.url.map(JSONValue.string) ?? .null,
         "title": order.title.map(JSONValue.string) ?? .null, "focus": .bool(order.focus)]
    }
    private static func pane(_ broker: ServerUIBroker, name: String, arguments: [String: JSONValue], workspaceID: WorkspaceID) async -> PaneOutcome {
        let result = await broker.perform(.init(name: name, arguments: .object(arguments)), workspaceID: workspaceID)
        return result.isError ? .refused(result.text) : .opened(result.text)
    }
    private static func output(_ result: RemoteUIResult) -> BridgeToolResult {
        if result.isError { return .failure(result.text) }
        if let png = result.png { return .picture(BridgeToolImage(png: png), saying: result.text) }
        if let value = result.value { return .json(value) }
        return BridgeToolResult(text: result.text)
    }
}
