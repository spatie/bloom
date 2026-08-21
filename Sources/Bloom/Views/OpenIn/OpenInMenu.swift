import SwiftUI
import AppKit
import BloomCore

/// What is being handed to another application, and which it is.
///
/// A file and the folder it is in are two different things with the same verb, and "Open in Zed"
/// on a row that names a file has to mean the file. So the target carries its own kind, every menu
/// built from it says which kind it is in its own title, and an application that cannot do
/// anything useful with that kind is not offered it. See `OpenTargets`.
enum OpenInTarget: Hashable {
    case file(String)
    case folder(String)

    var path: String {
        switch self {
        case .file(let path), .folder(let path): path
        }
    }

    var kind: OpenTargets {
        switch self {
        case .file: .file
        case .folder: .folder
        }
    }

    /// The folder a file is in, which is what a terminal or a git client is given instead.
    var enclosingFolder: String {
        switch self {
        case .file(let path): (path as NSString).deletingLastPathComponent
        case .folder(let path): path
        }
    }
}

extension EnvironmentValues {
    /// The project a path belongs to, so the menu can remember an editor per project.
    ///
    /// In the environment rather than passed down, because every row in the changed file list and
    /// the worktree tree would otherwise carry a repository id it has no other use for, through
    /// three layers of view that have no other use for it either. Set once, at the top of the
    /// inspector. Absent is fine: the menu falls back to whatever was used last anywhere.
    @Entry var openInRepoID: RepoID?
}

/// Hands a path to another application, and remembers which one.
enum OpenIn {
    static func open(_ path: String, with app: DetectedApp, repo: RepoID?) {
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: path)],
            withApplicationAt: app.url,
            configuration: NSWorkspace.OpenConfiguration()
        )
        OpenInPreferences().record(app.app.bundleID, repo: repo)
    }

    /// Everywhere this path can be opened, in the order the menu shows them.
    ///
    /// One function for the submenu and for every control that opens a path without going through
    /// a menu at all, so the two can never name different applications, and so an application the
    /// system contributed can reach the top of the list the same way a catalogued one does.
    @MainActor
    static func candidates(for target: OpenInTarget, repo: RepoID?) -> [DetectedApp] {
        var apps = InstalledApps.all.filter { $0.app.opens(target.kind) }
        if case .file(let path) = target, let extra = InstalledApps.systemDefault(forFile: path) {
            apps.append(extra)
        }
        let order = EditorCatalog.ordered(
            apps.map(\.app), lastUsed: OpenInPreferences().lastUsed(repo: repo)
        )
        return order.compactMap { app in apps.first { $0.id == app.bundleID } }
    }

    /// The ones that can do nothing with a file but can do something with the folder it is in.
    ///
    /// A terminal or a git client handed a single file has nothing to do with it, so it is offered
    /// the folder instead, under a heading that says so. Silently substituting one for the other
    /// would be the ambiguity `OpenInTarget` exists to avoid. Empty for a folder, which already is
    /// the thing they want.
    ///
    /// Here rather than beside the rows that draw it, because whether the submenu has anything at
    /// all in it is decided one level up, by the menu that would otherwise be a dead row.
    @MainActor
    static func enclosing(for target: OpenInTarget, repo: RepoID?) -> [DetectedApp] {
        guard case .file(let path) = target else { return [] }
        let folder = OpenInTarget.folder((path as NSString).deletingLastPathComponent)
        return candidates(for: folder, repo: repo).filter { !$0.app.opens(.file) }
    }

    /// The application a press opens: whatever this project was last opened in, and failing that
    /// whatever anything was last opened in, and failing that the first of the catalogue.
    @MainActor
    static func preferred(for target: OpenInTarget, repo: RepoID?) -> DetectedApp? {
        candidates(for: target, repo: repo).first
    }
}

/// The menu items a path gets: one submenu holding everywhere it can be opened.
///
/// It used to be two: a direct "Open in Zed" and this submenu under it. Both came from
/// `OpenIn.candidates` and the submenu puts the last used application at the top, so the direct
/// item and the submenu's first row named the same application every time. Two rows one above the
/// other saying the same thing is what got the direct one taken out.
///
/// **It costs a hover, and there is no arrangement that avoids that.** Opening the worktree in the
/// editor you always use was a click in this menu and is now a click and a hover. The obvious
/// compromise, letting the submenu's own parent row open the preferred application, is not
/// available: AppKit never sends the action of an item that has a submenu, which is the same limit
/// `TerminalPaneMenu.splitItem` writes a key equivalent around. SwiftUI will happily let you write
/// it, and that is the trap. `Menu { } primaryAction: { }` inside a menu builds an item carrying
/// BOTH an action and a submenu, which was read back off the built `NSHostingMenu` item by item,
/// and the action is then silently never delivered.
///
/// So the click is kept where a CONTROL rather than a menu item can carry it, and those are the
/// places it was actually being used: `FilePreview`'s open button fires the preferred application
/// on its primary action and shows this list on a hold, and `SlashCommandChip` draws its own
/// button on the chip. A workspace keeps Open in Editor on its row menu and Cmd+Shift+E on the
/// menu bar, but those two are `Reveal.inEditor`, which tries VS Code, Cursor and Xcode in that
/// fixed order and knows nothing about the editor this menu remembers per project. They agree on
/// this machine by coincidence. Closing that gap is worth doing and is not this change.
struct OpenInItems: View {
    let target: OpenInTarget
    /// Overrides the submenu's title, for a place where "file" or "folder" is not what the thing
    /// is called. The worktree, for instance.
    var noun: String?

    @Environment(\.openInRepoID) private var repoID

    var body: some View {
        // Nothing takes this path as it is, which on a developer's Mac means the catalogue is
        // wrong rather than that there is no editor. Without this the reader is left with a
        // submenu that is greyed out, or that offers only the folder a file sits in, and no way at
        // all to open the thing they asked about. Hand it to whatever the system would. It
        // duplicates nothing, because there is nothing for it to duplicate.
        if OpenIn.preferred(for: target, repo: repoID) == nil {
            Button("Open in Editor") { Reveal.inEditor(target.path) }
        }

        OpenInMenu(target: target, noun: noun)
    }
}

/// Everywhere this path can be opened, as a submenu.
///
/// Greyed rather than gone when nothing can open the path at all, which is the state a menu item
/// with nothing behind it is meant to be in. `OpenInItems` is what puts a way out beside it.
struct OpenInMenu: View {
    let target: OpenInTarget
    var noun: String?

    @Environment(\.openInRepoID) private var repoID

    var body: some View {
        Menu(title) {
            OpenInAppItems(target: target)
        }
        .disabled(
            OpenIn.candidates(for: target, repo: repoID).isEmpty
                && OpenIn.enclosing(for: target, repo: repoID).isEmpty
        )
    }

    private var title: String {
        if let noun { return "Open \(noun) in" }
        return switch target {
        case .file: "Open File in"
        case .folder: "Open Folder in"
        }
    }
}

/// The applications themselves, as flat rows.
///
/// Its own view so that a control whose press already means "open this" can show the list without
/// a submenu in front of it. `FilePreview`'s button is that control: its primary action opens the
/// preferred application, so a menu holding a single row you then have to hover would be a menu
/// with nothing in it. A context menu, where "open" is one of several things the row can do, gets
/// `OpenInMenu` instead.
///
/// Ordered by `EditorCatalog.ordered`: the application used last at the top, everything else in
/// the catalogue's own fixed order under it.
///
/// # No numbers
///
/// Conductor numbers these 1 to 9. Bloom does not, and the reason is the request that came with
/// them: the most recently used application moves to the top. A number is only worth learning if
/// it means the same thing tomorrow, and once the list reorders, "3" is whatever happens to be
/// third today. AppKit already gives a menu a stable accelerator that survives reordering, which
/// is the first letter of the name: `z` finds Zed wherever Zed currently sits. That is the
/// shortcut worth having here, and it costs nothing to leave in place.
struct OpenInAppItems: View {
    let target: OpenInTarget

    @Environment(\.openInRepoID) private var repoID

    var body: some View {
        ForEach(direct) { app in
            item(app, path: target.path)
        }

        // The applications that can only take the folder, under a heading that says so. See
        // `OpenIn.enclosing` for why they are offered at all.
        if !enclosing.isEmpty {
            Section("Its folder") {
                ForEach(enclosing) { app in
                    item(app, path: target.enclosingFolder)
                }
            }
        }
    }

    /// The applications that take this path as it is.
    private var direct: [DetectedApp] { OpenIn.candidates(for: target, repo: repoID) }

    /// The ones that only make sense given the folder, shown only on a file.
    private var enclosing: [DetectedApp] { OpenIn.enclosing(for: target, repo: repoID) }

    private func item(_ app: DetectedApp, path: String) -> some View {
        Button {
            OpenIn.open(path, with: app, repo: repoID)
        } label: {
            Label {
                Text(app.app.name)
            } icon: {
                Image(nsImage: app.icon)
            }
        }
    }
}
