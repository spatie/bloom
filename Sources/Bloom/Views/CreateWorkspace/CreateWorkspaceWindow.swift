import SwiftUI
import BloomCore

/// The window a workspace is started in.
///
/// **A window rather than a sheet, and the reason is the one moment it is used.** Writing the task
/// is when a person most wants to read the code they are describing: the workspace they are
/// copying a path out of, the transcript that says what went wrong, the sidebar row they are about
/// to start beside. A sheet is pinned to the top of the main window and blocks all of it, so the
/// answer to "what was that branch called" was to cancel, look, and type it again from memory.
/// This can be dragged off to the side and the main window read behind it. It is what Keynote's
/// theme chooser and every other new-document window on the Mac already are, and the owner asked
/// for it by putting the two side by side.
///
/// One window per project, because `openWindow(id:value:)` reuses the window already presenting a
/// value rather than opening a second one: asking again while it is open brings it forward with
/// whatever has been typed in it still there. Two projects can have one each, which is the same
/// rule `RepoSettingsWindow` keeps and for the same reason.
///
/// Keyed by the project's id rather than by the whole `Repo`, so a window resolves against the
/// database as it is now rather than against a snapshot of a project that may since have been
/// renamed or removed.
struct CreateWorkspaceWindow: Scene {
    let model: AppModel

    /// The scene id. Opening this window from anywhere is `openWindow(id:value:)` with it.
    static let id = "create-workspace"

    var body: some Scene {
        WindowGroup("New Workspace", id: Self.id, for: RepoID.self) { $repoID in
            CreateWorkspaceWindowContent(repoID: repoID)
                .environment(model)
                // Cmd+W, and not Escape from the key monitor. Escape belongs to what is inside
                // this window: the composer's completion menus take it first, and only what they
                // did not want cancels. A monitor that closed the window on every Escape would
                // take the key off the `@` menu that was open at the time. See `WindowRoles`.
                .windowRole(.utility)
        }
        // Exactly its content, which is also why it is not resizable. The width is
        // `CreateWorkspaceView.width`, measured against the footer's five labelled controls, and
        // the height is whatever the chosen mode needs: a window that could be dragged taller
        // would hand every extra point to a blank margin, because the only thing here that could
        // use one is the writing box and its height follows what is typed. Choosing a mode
        // resizes the window for the same reason, which is what keeps the card honest about how
        // little terminal mode has in it.
        .windowResizability(.contentSize)
        // The same verdict `RepoSettingsWindow` reached, one step stronger. A restored create
        // window would come back at the next launch holding a draft nobody has looked at since,
        // against a project list that is empty until the store answers, and `openWindow` raising
        // a window that is behind or on another Space is unreliable enough that the menu item
        // would then look like it did nothing. Nothing here is worth restoring: no worktree has
        // been cut yet, and the item is Cmd+N away.
        .restorationBehavior(.disabled)
    }
}

/// Resolves the id to a project every time the database changes.
///
/// A project that has been removed is not an error here, which is the one difference from
/// `RepoSettingsWindow`: this window has a project picker in its own header, so the honest answer
/// to "that project is gone" is the same fallback the view makes when it is opened with no project
/// at all. `CreateWorkspaceView.load` picks the selected workspace's project, or the first one, or
/// puts up the empty state when there are no projects left to start in.
private struct CreateWorkspaceWindowContent: View {
    let repoID: RepoID?

    @Environment(AppModel.self) private var app

    var body: some View {
        CreateWorkspaceView(initialRepo: app.repos.first { $0.id == repoID })
    }
}

/// What the window is being asked to open on, for the one caller that asks for anything.
///
/// **Read once and cleared**, the same shape as `WorkspaceStartMode.consumeOpeningTab` and for the
/// same reason: it is a hint about a moment, and a flag left standing would raise the pull request
/// box again the next time this window was opened for any reason at all.
///
/// It is not part of the window's value, and that is deliberate. The value is what makes one
/// window per project; a flag inside it would make "New Workspace" and "New Workspace from Pull
/// Request…" two different values, and so two windows open on the same project at once.
///
/// Observable rather than a plain static, so a window that is ALREADY open when the menu item is
/// pressed raises its box too. That is the case a value could not have handled either way: the
/// window is not rebuilt when it is merely brought forward.
@MainActor
@Observable
final class CreateWorkspaceOpening {
    static let shared = CreateWorkspaceOpening()

    /// Set by the File menu's pull request item and by nothing else.
    ///
    /// It raises the box for a number or a URL rather than the list of open ones, because that is
    /// the half a menu item can actually put in front of somebody: the list is a network call that
    /// has not landed when the window opens, and it cannot offer a closed pull request, somebody
    /// else's, or the hundred and first of a busy repository. The list is still one click away in
    /// the "Start from" control the window opens with.
    private(set) var wantsPullRequest = false

    private init() {}

    func askForPullRequest() {
        wantsPullRequest = true
    }

    /// True once. The window that honours it clears it, so the next open is an ordinary one.
    func consumePullRequestAsk() -> Bool {
        guard wantsPullRequest else { return false }
        wantsPullRequest = false
        return true
    }

    /// A name to open the window with, set by the search panel's "start a workspace called this"
    /// row and by nothing else.
    ///
    /// Somebody who searched for a workspace that does not exist has just said what they want it
    /// called, and asking them to type it again is the panel throwing that away. It lands in the
    /// name field, which the two modes that run no agent draw; chat mode has no such field because
    /// it names the workspace from the prompt, so there this is what the field would have held if
    /// they change their mind about the mode.
    private(set) var suggestedName: String?

    func askForName(_ name: String) {
        suggestedName = name
    }

    /// Once, like the pull request ask above.
    func consumeName() -> String? {
        defer { suggestedName = nil }
        return suggestedName
    }
}
