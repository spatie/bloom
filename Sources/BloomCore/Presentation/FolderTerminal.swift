import Foundation

/// Opening a shell in one folder of a worktree rather than at its root.
///
/// The rules, not the tab. Three questions live here because three different places ask them and
/// none of those places can be tested: the two file trees in the inspector ask whether to offer
/// the item and what the tab would be called, and `TerminalSessionStore` asks where the shell is
/// actually forked at the moment it forks one.
public enum FolderTerminal {
    /// One name for the item, because two trees in the same pane draw it. `Open` rather than `New`
    /// to sit with `Reveal in Finder` and `Open Folder in`, which is the group it belongs to.
    public static let menuTitle = "Open Terminal Tab Here"

    /// What a row's item resolves to: where the shell goes, and what the tab is called.
    public struct Target: Sendable, Equatable {
        /// Absolute, because that is what a launch takes.
        public var directory: String
        public var title: String

        public init(directory: String, title: String) {
            self.directory = directory
            self.title = title
        }
    }

    /// Whether the item is offered for a folder at all.
    ///
    /// Absent rather than present and refusing, for a folder that is not on disk. The changed file
    /// tree draws its directories out of a diff, so it shows one the agent has just deleted, and a
    /// workspace keeps its rows after its worktree has been removed. `Reveal in Finder` next to it
    /// can hand a dead path to another application and let that application shrug; this one would
    /// leave a tab in Bloom's own window holding a shell that never started, which is a mess the
    /// reader then has to clear up. Absent rather than greyed is what the Run submenu next door
    /// already does with an empty list.
    public static func canOpen(folder path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }

    /// The tab to make for a folder, or nothing if it has gone between the right click and the
    /// click.
    ///
    /// Named after the folder rather than `Terminal 3`, so somebody who asked for a shell in
    /// `resources/css` can see which of their tabs it is. `taken` is the workspace's other
    /// terminal titles, so two shells in two folders both called `css` are told apart by exactly
    /// the numbering every other pane is named by.
    public static func target(folder path: String, taken: some Sequence<String>) -> Target? {
        guard canOpen(folder: path) else { return nil }
        let name = (path as NSString).lastPathComponent
        let base = name.isEmpty ? PaneNaming.terminal : name
        return Target(directory: path, title: PaneNaming.nextTitle(base: base, taken: taken))
    }

    /// Where a terminal tab's shell is forked.
    ///
    /// The folder it was opened in while that is still there, and the worktree root otherwise. A
    /// tab outlives the folder under it: checking out another branch takes directories with it,
    /// and the tab comes back from user defaults on the next launch whatever the worktree looks
    /// like by then. A shell forked into a path that is not there is a pane that never draws a
    /// prompt, so the root answers instead.
    public static func launchDirectory(requested: String, root: String) -> String {
        guard !requested.isEmpty, canOpen(folder: requested) else { return root }
        return requested
    }
}
