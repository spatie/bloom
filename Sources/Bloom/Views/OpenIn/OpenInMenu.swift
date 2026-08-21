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
    /// One function for the submenu and for the item above it, so the two can never name different
    /// applications, and so an application the system contributed can reach the top of the list
    /// the same way a catalogued one does.
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

    /// The application the top item opens: whatever this project was last opened in, and failing
    /// that whatever anything was last opened in, and failing that the first of the catalogue.
    @MainActor
    static func preferred(for target: OpenInTarget, repo: RepoID?) -> DetectedApp? {
        candidates(for: target, repo: repo).first
    }
}

/// The two menu items a path gets: the one that opens it, and the list of everywhere else.
///
/// Both, rather than only the submenu, because opening a file in the editor you always use is the
/// common case and it was one click before this existed. A submenu that has to be hovered to reach
/// the same application is a worse menu, however complete it is. The direct item names the
/// application rather than saying "Editor", so what it will do is legible without opening
/// anything.
struct OpenInItems: View {
    let target: OpenInTarget
    /// Overrides the submenu's title, for a place where "file" or "folder" is not what the thing
    /// is called. The worktree, for instance.
    var noun: String?

    @Environment(\.openInRepoID) private var repoID

    var body: some View {
        if let app = OpenIn.preferred(for: target, repo: repoID) {
            Button("Open in \(app.app.name)") { OpenIn.open(target.path, with: app, repo: repoID) }
        } else {
            // Nothing at all was detected, which on a developer's Mac means the catalogue is
            // wrong rather than that there is no editor. Hand it to whatever the system would.
            Button("Open in Editor") { Reveal.inEditor(target.path) }
        }

        OpenInMenu(target: target, noun: noun)
    }
}

/// Everywhere this path can be opened, as a submenu.
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
struct OpenInMenu: View {
    let target: OpenInTarget
    var noun: String?

    @Environment(\.openInRepoID) private var repoID

    var body: some View {
        Menu(title) {
            ForEach(direct) { app in
                item(app, path: target.path)
            }

            // A terminal or a git client handed a single file has nothing to do with it, so it is
            // offered the folder the file is in instead, under a heading that says so. Silently
            // substituting one for the other would be the ambiguity this whole type is avoiding.
            if case .file = target, !enclosing.isEmpty {
                Section("Its folder") {
                    ForEach(enclosing) { app in
                        item(app, path: target.enclosingFolder)
                    }
                }
            }
        }
        .disabled(direct.isEmpty && enclosing.isEmpty)
    }

    private var title: String {
        if let noun { return "Open \(noun) in" }
        return switch target {
        case .file: "Open File in"
        case .folder: "Open Folder in"
        }
    }

    /// The applications that take this path as it is.
    private var direct: [DetectedApp] { OpenIn.candidates(for: target, repo: repoID) }

    /// The ones that only make sense given the folder, shown only on a file.
    private var enclosing: [DetectedApp] {
        guard case .file(let path) = target else { return [] }
        let folder = OpenInTarget.folder((path as NSString).deletingLastPathComponent)
        return OpenIn.candidates(for: folder, repo: repoID).filter { !$0.app.opens(.file) }
    }

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
