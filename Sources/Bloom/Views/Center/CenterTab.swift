import Foundation
import BloomCore

/// A tab in the centre column that is not a conversation.
///
/// Chat tabs are `Session` rows in SQLite and stay that way: a conversation is the thing the app
/// exists to keep. A terminal, a browser and a file are not. A shell dies with the process that
/// forked it, a page is one string and a file is one path into a worktree git can be asked about
/// again, so none of them earns a table, a migration or a store. What is worth remembering is only
/// which tabs the user had open, which is small enough to keep in user defaults and cheap enough
/// to lose.
///
/// `review` is the odd one and is deliberately not "a tab per file". A workspace has exactly one
/// of it, and clicking another file points it somewhere else rather than opening a second tab.
/// That is what Conductor does: every diff tab it can make collapses onto one identity, and its
/// label names the range being reviewed rather than the file under the cursor. Reading a change is
/// one activity that walks over many files, so it is one tab, and a strip that grew a tab per file
/// would bury the conversations the strip is mostly for.
struct CenterTab: Identifiable, Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case terminal
        case browser
        /// The changed files of this workspace, read one at a time.
        case review
    }

    var id: String = newID()
    var workspaceID: WorkspaceID
    var kind: Kind
    var title: String
    /// Browser only, and kept up to date as the user navigates, so reopening the workspace lands
    /// on the page they were looking at rather than back on the dev server's front door.
    var url: String = ""
    /// Review only: the file being read, relative to the worktree. Kept here rather than taken
    /// from `WorkspaceModel.selectedFilePath` because that one is only ever a CHANGED file: the
    /// poll drops any selection git no longer reports, which would throw the reader out of a file
    /// they opened from the worktree tree a few seconds after they opened it.
    var path: String = ""

    /// The glyph that tells the kinds apart in the strip. Chat tabs carry none, which is what
    /// keeps a row of conversations from reading as a toolbar of icons.
    var icon: String {
        switch kind {
        case .terminal: "apple.terminal"
        case .browser: "globe"
        case .review: "doc.text"
        }
    }

    /// What a review tab is called when it is empty or reading a file the agent changed. A file
    /// nobody changed is named by `CenterTabStore.displayTitle`, which can see the workspace.
    static let reviewTitle = "All changes"

    // MARK: - Decoding

    /// Written out by hand for one reason: a synthesized `Decodable` does not fall back to a
    /// property's default value when the key is missing, it throws. Every tab already written to
    /// user defaults predates `path`, so the synthesized version would have failed on the whole
    /// array and quietly closed every terminal and browser tab the user had open when they next
    /// launched. A field added later has to be read as optional even when it is stored as not.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        workspaceID = try container.decode(WorkspaceID.self, forKey: .workspaceID)
        kind = try container.decode(Kind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
    }

    init(id: String = newID(), workspaceID: WorkspaceID, kind: Kind, title: String, url: String = "", path: String = "") {
        self.id = id
        self.workspaceID = workspaceID
        self.kind = kind
        self.title = title
        self.url = url
        self.path = path
    }
}
