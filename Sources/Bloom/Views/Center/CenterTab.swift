import Foundation
import BloomCore

/// A tab in the centre column that is not a conversation.
///
/// Chat tabs are `Session` rows in SQLite and stay that way: a conversation is the thing the app
/// exists to keep. A terminal and a browser are not. A shell dies with the process that forked it
/// and a page is one string, so neither earns a table, a migration or a store. What is worth
/// remembering is only which tabs the user had open, which is small enough to keep in user
/// defaults and cheap enough to lose.
struct CenterTab: Identifiable, Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case terminal
        case browser
    }

    var id: String = newID()
    var workspaceID: String
    var kind: Kind
    var title: String
    /// Browser only, and kept up to date as the user navigates, so reopening the workspace lands
    /// on the page they were looking at rather than back on the dev server's front door.
    var url: String = ""

    /// The glyph that tells the kinds apart in the strip. Chat tabs carry none, which is what
    /// keeps a row of conversations from reading as a toolbar of icons.
    var icon: String {
        switch kind {
        case .terminal: "apple.terminal"
        case .browser: "globe"
        }
    }
}
