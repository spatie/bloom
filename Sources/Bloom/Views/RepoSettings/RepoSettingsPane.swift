import AppKit
import Foundation

/// Which part of a project's settings is showing.
///
/// A type of its own rather than an enum nested inside the view, because three things outside
/// that view now answer to it: the toolbar that draws the choice, the window that has to say
/// which item is selected, and a capture run that names the pane it wants photographed.
///
/// Named `Pane` rather than `Tab` because `Tab` is SwiftUI's own type, and because these are not
/// tabs any more: they are toolbar items. See `RepoSettingsToolbar` for why.
enum RepoSettingsPane: String, CaseIterable, Hashable {
    case project
    case workspaces
    case scripts
    case instructions

    /// The word under the icon.
    var title: String {
        switch self {
        case .project: "Project"
        case .workspaces: "Workspaces"
        case .scripts: "Scripts"
        case .instructions: "Instructions"
        }
    }

    /// The symbol above that word. A preference toolbar is icons with their words underneath, so
    /// every pane has to have one, which is why this is not optional.
    var systemImage: String {
        switch self {
        case .project: "folder"
        case .workspaces: "square.stack.3d.up"
        case .scripts: "terminal"
        case .instructions: "text.book.closed"
        }
    }

    /// What this pane is called inside the toolbar.
    ///
    /// Derived from the case rather than written out a second time in a table beside it. An
    /// identifier that disagrees with its case is a toolbar item that draws and cannot be
    /// selected, which is a fault with nothing on screen to say what went wrong.
    var itemIdentifier: NSToolbarItem.Identifier {
        NSToolbarItem.Identifier("repo-settings.\(rawValue)")
    }

    /// Which pane a window opens on, from `BLOOM_PANE=workspaces|scripts|instructions`.
    ///
    /// A capture run can open this window through `--repo-settings` and cannot press anything in
    /// it, so without this the other two panes go in unverified. Nil for anything else, including
    /// nothing at all, and the window falls back to Project.
    static var requested: RepoSettingsPane? {
        guard let named = ProcessInfo.processInfo.environment["BLOOM_PANE"] else { return nil }
        return RepoSettingsPane(rawValue: named)
    }
}
