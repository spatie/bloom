import Foundation

/// What one pane is showing.
///
/// A pane holds a pointer, never the content itself. The transcript, the shell and the web view
/// all hang off the stores that own them, so closing a pane can never take a running agent with
/// it by accident.
///
/// Chats and tools are told apart because they are stored apart. A conversation is a row in SQLite
/// that outlives the launch; a terminal or a page is a line in user defaults that is better lost
/// than migrated. That is the whole difference, and it is why there are two cases rather than a
/// kind and an id.
///
/// It lives in the core rather than beside the views because two decisions are taken about it that
/// have to be testable: which of these things earns a tab of its own, and what a workspace's panes
/// become when they are folded into one. `Tests/BloomCoreTests` cannot see `Sources/Bloom` at all,
/// so a decision left there is a decision nothing can hold still.
///
/// **The `Codable` shape is a file format.** It is what `center.panes.<workspaceID>` was written
/// with, and moving the type between modules must not change a byte of it, so the case names stay
/// `chat` and `tool` and the conformance stays synthesized. `PaneContentWireFormatTests` decodes a
/// hand written literal for the same reason `IdentifierTests` pins a raw value: the shape is
/// inherited from the compiler and nothing here would notice it changing.
public enum PaneContent: Codable, Hashable, Sendable {
    case chat(SessionID)
    case tool(String)

    /// The id on its own, with the kind thrown away.
    ///
    /// Both sides are `newID()` uuids drawn from namespaces that never meet, so one string names
    /// one thing. That is what lets a tab be filed under the content at its root without the key
    /// having to carry a discriminator as well.
    public var id: String {
        switch self {
        case .chat(let id): id.rawValue
        case .tool(let id): id
        }
    }

    var isChat: Bool {
        if case .chat = self { return true }
        return false
    }
}
