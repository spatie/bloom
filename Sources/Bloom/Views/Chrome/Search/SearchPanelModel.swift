import AppKit
import SwiftUI
import BloomCore

/// Whether the panel is open, what is in its field, and which row is highlighted.
///
/// **A shared object rather than `@State` in the window**, for the same reason `FeedbackPresenter`
/// and `SetupRunAlert` are: a `Commands` body is not a view and cannot reach a `@State`, and the
/// two keys that open this are menu items. It is also what lets the toolbar's magnifying glass and
/// the Edit menu open the same panel rather than two.
///
/// Everything it decides is in the core. What is here is the state those decisions are taken
/// against, and the wiring to `AppModel`: the archived list, the transcript search and the two
/// ways a row is opened.
@MainActor
@Observable
final class SearchPanelModel {
    static let shared = SearchPanelModel()

    private(set) var isOpen = false
    private(set) var field = SearchPanelField()
    var scope: HomeScope = .all
    /// An index into `listing.rows`, never into a section. See `SearchPanelListing.rows`.
    var highlighted: Int?
    private(set) var listing = SearchPanelListing.empty
    /// Which menu bar items the bar would actually fire right now, read once per rebuild. See
    /// `MainMenuActions.runnable`.
    private(set) var runnable: Set<MenuBarAction> = []
    /// Bumped when Cmd+K is pressed at an already open panel, which is the platform's answer to
    /// pressing a find key twice: select what is in the field rather than opening a second one.
    private(set) var selectAllToken = 0
    /// The archived workspaces, loaded when the panel opens. Old work is most of what the search
    /// half is for, so the list is not complete without them.
    private(set) var archived: [Workspace] = []
    /// Where the caret is, which is what decides whether the right arrow pushes into a row or
    /// moves the caret one character. See `SearchPanelKeys`.
    var caretAtEnd = true

    private init() {}

    // MARK: - Opening and closing

    /// - Parameter scope: the chip to open on. Shift+Cmd+F opens on Transcripts, which is what that
    ///   key has always meant, and Cmd+K opens on Everything.
    func open(scope: HomeScope = .all, app: AppModel) {
        if isOpen {
            // The platform's rule for pressing a find key at an open find: select what is there,
            // so the next character replaces the query rather than extending it.
            selectAllToken &+= 1
        } else {
            isOpen = true
            field = SearchPanelField()
            highlighted = nil
            listing = .empty
        }
        self.scope = HomeScope.settle(scope, searching: true)
        Task { archived = await app.archivedWorkspaces() }
        rebuild(app: app)
    }

    /// Closing leaves the window exactly where it was. Nothing about the selection, the scroll or
    /// the sidebar moves, which is the whole difference between this and the field it replaced.
    func close(app: AppModel) {
        guard isOpen else { return }
        isOpen = false
        field = SearchPanelField()
        scope = .all
        highlighted = nil
        listing = .empty
        // The store's half is cleared with it, or the next search would open on the answer to the
        // last one for as long as the debounce takes.
        app.searchTranscripts("")
    }

    // MARK: - Typing

    func type(_ text: String, app: AppModel) {
        let before = field.mode
        field.type(text)
        // Only when it moved. `searchTranscripts` cancels whatever is running, so calling it on a
        // keystroke that changed no query would throw away an answer that was about to land.
        if before != field.mode || field.mode == .things {
            app.searchTranscripts(field.mode == .things ? field.query : "")
        }
        rebuild(app: app)
    }

    /// Pushes into the highlighted row's own menu, if it has one.
    @discardableResult
    func drill(app: AppModel) -> Bool {
        guard let row = listing.row(at: highlighted), let id = row.drillable else { return false }
        guard field.enterActions(on: id) else { return false }
        app.searchTranscripts("")
        rebuild(app: app)
        return true
    }

    @discardableResult
    func leaveMode(app: AppModel) -> Bool {
        guard field.leaveMode() else { return false }
        app.searchTranscripts(field.mode == .things ? field.query : "")
        rebuild(app: app)
        return true
    }

    func clearQuery(app: AppModel) {
        field.clear()
        app.searchTranscripts("")
        rebuild(app: app)
    }

    func setScope(_ scope: HomeScope, app: AppModel) {
        self.scope = scope
        rebuild(app: app)
    }

    // MARK: - Building the list

    /// One pass, on the same inputs Home builds its list from, called when those inputs move
    /// rather than while drawing.
    func rebuild(app: AppModel) {
        guard isOpen else { return }
        switch field.mode {
        case .things:
            listing = field.isEmpty
                ? SearchPanelResting.build(
                    workspaces: app.workspaces,
                    repos: app.repos,
                    activity: HomeActivity(
                        running: app.runningWorkspaceIDs, waiting: app.waitingWorkspaceIDs
                    )
                )
                : SearchPanelResults.build(
                    query: field.query,
                    repos: app.repos,
                    workspaces: app.workspaces,
                    archived: archived,
                    transcripts: app.transcriptResults,
                    scope: scope,
                    hasProjects: !app.repos.isEmpty
                )
        case .commands:
            listing = SearchPanelListing(
                sections: SearchPanelCommands.sections(SearchPanelCommands.rank(field.query)),
                isSearching: !field.isEmpty
            )
        case .actions(let id):
            listing = SearchPanelListing(sections: SearchPanelActions.sections(for: subject(id)))
        }

        runnable = MainMenuActions.runnable()
        // The highlight follows the list rather than the list following the highlight. A row index
        // held over a rebuild is how a panel opens the workspace above the one being looked at.
        highlighted = listing.rows.isEmpty ? nil : min(highlighted ?? 0, listing.rows.count - 1)
    }

    /// Which kind of subject a drilled workspace is, which decides what it can be asked to do.
    private func subject(_ id: WorkspaceID) -> WorkspaceMenuSubject {
        archived.contains { $0.id == id } ? .archived(id) : .live(id)
    }

    /// The workspace an action list is about, for the pill in the field.
    func drilledWorkspace(app: AppModel) -> Workspace? {
        guard let id = field.mode.workspaceID else { return nil }
        return app.workspaces.first { $0.id == id } ?? archived.first { $0.id == id }
    }

    // MARK: - The keyboard

    var keyContext: SearchPanelKeyContext {
        SearchPanelKeyContext(
            mode: field.mode,
            rowCount: listing.rows.count,
            highlighted: highlighted,
            isQueryEmpty: field.isEmpty,
            scope: scope,
            scopes: HomeScope.offered(searching: true),
            canDrill: listing.row(at: highlighted)?.drillable != nil,
            caretAtEnd: caretAtEnd
        )
    }
}
