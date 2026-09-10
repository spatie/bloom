import Foundation
import BloomCore
import BloomClient

/// Remote tool calls enter the same Mac handlers as local tools, scoped to the workspace whose
/// visible client holds the lease. No route activates another application or selects another workspace.
@MainActor
struct RemoteUIActionRouter {
    @TaskLocal static var serverScope: ServerWindowModel?
    static let actions = [
        "pane_open", "pane_split", "pane_close", "pane_rename", "pane_list", "workspace_tabs", "workspace_tab_select",
        "browser_read", "browser_reload", "browser_go", "browser_screenshot", "browser_scroll", "browser_text",
        "terminal_start", "terminal_read", "terminal_write", "terminal_send_key", "media_show",
    ]

    let app: AppModel
    let server: ServerWindowModel
    let workspaceID: WorkspaceID

    func perform(_ action: RemoteUIAction) async -> RemoteUIResult {
        guard !Task.isCancelled, app.remoteServer === server, server.selectedWorkspace?.id == workspaceID,
              app.selection == .remoteWorkspace(workspaceID),
              server.existingWorkspaceModel(workspaceID) != nil else {
            return .refusal("This workspace is no longer selected in this client. Reopen it before retrying.")
        }
        guard Self.actions.contains(action.name), let store = app.store,
              let handler = app.bridgeToolbox().handler(named: action.name, for: .parent) else {
            return .refusal("This client does not support that UI action.")
        }
        // These are exclusively workspace UI handlers. Their session value is never used for
        // execution; the server already authenticated and scoped the real calling agent.
        let identity = BridgeIdentity(sessionID: server.selectedSessionID ?? SessionID("remote-ui"), workspaceID: workspaceID, role: .parent)
        let result = await Self.$serverScope.withValue(server) {
            await handler.call(MCPRequest(id: .string(UUID().uuidString), method: action.name, params: action.arguments), as: identity, store: store)
        }
        return RemoteUIResult(text: result.text, isError: result.isError, value: result.image == nil ? JSONValue.parse(Data(result.text.utf8)) : nil, png: result.image?.data)
    }
}
