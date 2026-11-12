import Foundation

/// A link to a workspace, or to one chat in it, that a chat may draw and open.
///
/// **Navigation and nothing else, which is the whole of why it is safe to click.** Bloom's scheme
/// carries two kinds of link. `workspace/<id>?chat=<id>` shows something that already exists, the
/// same thing a click in the sidebar does. The older `?prompt=&path=` form starts an agent in a
/// project, and a chat is the last place that one may be pressed: everything an agent writes is
/// downstream of what it read, so a page or an issue could put a one click "start an agent with
/// these instructions" in front of the owner. Only the first kind is a `WorkspaceLink`, and the
/// transcript opens nothing else of Bloom's own (`LinkPolicy.opens`).
///
/// Only this copy's own scheme counts, as with an incoming deep link. A `bloom://` link in the dev
/// copy is somebody else's workspace id, and opening it would answer "Workspace not found" about
/// a workspace that is real, just not here.
public struct WorkspaceLink: Equatable, Sendable {
    public let workspaceID: WorkspaceID
    public let chatID: SessionID?

    public init?(_ url: URL, schemes: Set<String> = BloomURLScheme.own) {
        guard case let .workspace(id, chatID)? = try? BloomLinkRequest(url: url, schemes: schemes) else { return nil }
        workspaceID = id
        self.chatID = chatID
    }

    /// The address that opens `workspace`, and `chat` in it when there is one. What the bridge
    /// hands an agent, so the link it writes back into a chat is the one this type reads.
    public static func address(
        workspace: WorkspaceID, chat: SessionID? = nil, scheme: String = BloomURLScheme.primary
    ) -> String {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = "workspace"
        parts.path = "/" + workspace.rawValue
        if let chat { parts.queryItems = [URLQueryItem(name: "chat", value: chat.rawValue)] }
        return parts.string ?? "\(scheme)://workspace/\(workspace.rawValue)"
    }

    /// The words of a menu item that opens it.
    public var openTitle: String { chatID == nil ? "Open Workspace" : "Open Chat" }
}
