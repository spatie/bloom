import SwiftUI
import BloomCore

/// What goes in the half that opens when the user asks for the pane they are in, again.
///
/// Splitting means the same thing twice in every editor on this platform, and for a conversation
/// it can: a transcript renders in two panes happily, which is why `TabSet` lets one chat sit in
/// two panes of one tab.
///
/// **A tool cannot be shown twice and never could.** A terminal and a browser are each one live
/// `NSView`, so the second pane takes the view away from the first, which then draws nothing. Cmd+\
/// on a shell has been able to ask for that since panes existed; it is a latent bug rather than a
/// feature, so it is refused here and a fresh one of the same kind is offered instead. Somebody
/// who asked for a second shell in this worktree gets a second shell in it.
///
/// Its own file beside `NewPane`, `BrowserTab` and `FileReview`, and it goes through `NewPane` for
/// everything it makes, so there is still exactly one door onto a new chat, terminal or browser.
@MainActor
enum PaneDuplicate {
    /// Works out what to put beside `content` and hands it to `place`.
    ///
    /// `place` is not called at all when there is nothing sensible to make. The review is the one
    /// case: a workspace has exactly one of it by design, opening it twice points the one tab at
    /// another file rather than making a second, so there is no fresh copy to offer. See
    /// `CenterTab`.
    static func open(
        _ content: PaneContent,
        in model: WorkspaceModel,
        place: @escaping @MainActor (PaneContent) -> Void
    ) {
        guard case .tool(let tabID) = content else { return place(content) }
        guard let tab = CenterTabStore.shared.tabs(for: model.workspace.id)
            .first(where: { $0.id == tabID }) else { return }

        switch tab.kind {
        case .terminal:
            NewPane.open(.terminal, in: model, place: place)

        // On the page it is already showing, rather than on the empty address a split browser
        // normally opens with. This is the one route that means "the same again", and the same
        // again is the same page.
        case .browser:
            NewPane.open(.browser, in: model, url: tab.url, place: place)

        case .review:
            return
        }
    }
}
