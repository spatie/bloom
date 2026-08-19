import Foundation

/// What one pane of the centre column is showing.
///
/// A pane holds a tab, not a kind of view. That is the whole idea behind splitting here: the strip
/// already lists everything a workspace can show, so a pane only has to say which of those things
/// it is pointing at, and every tab becomes something you can put side by side with any other.
///
/// Chats and tools are told apart because they are stored apart. A conversation is a row in SQLite
/// that outlives the launch; a terminal or a page is a line in user defaults that is better lost
/// than migrated. A pane that outlived what it pointed at falls back to whatever the workspace has
/// left, which is why `CenterPaneStore` resolves rather than trusts.
enum CenterPaneContent: Codable, Hashable, Sendable {
    case chat(String)
    case tool(String)
}
