import SwiftUI
import BloomCore

/// The one way a new chat, terminal or browser is made for the centre column.
///
/// `BrowserTab` and `FileReview` next door are the same shape and exist for the same reason: a
/// menu should not have to know how a session is created or where a tab is stored in order to put
/// one in front of the user, and every route to a terminal should produce exactly the tab a
/// terminal normally is. A chat goes through `WorkspaceModel.createSession`, a terminal and a
/// browser through `CenterTabStore.add`, which is what the strip's own `+` menu already called.
///
/// Where the tab goes is the caller's business, not this one's. The `+` shows it in the pane the
/// user is in; the pane's context menu splits and shows it in the half that opens. That is the
/// whole difference between the two, so it is the only thing that is passed in.
@MainActor
enum NewPane {
    /// Makes a tab of `kind` and hands it to `place`.
    ///
    /// `place` is called after the thing exists rather than before, which is why it is a closure
    /// and not a return value: a chat has to be written to SQLite first, and a session that fails
    /// to start must leave the column exactly as it was. Splitting first and filling afterwards
    /// would leave a second pane standing with a copy of the first one's conversation in it every
    /// time the agent could not be launched.
    ///
    /// `url` is only read for a browser. It is empty by default because a browser pane opened from
    /// a split has nowhere in particular to go: the address field is where somebody says. The
    /// strip's `+` passes the workspace's own dev server, which is what its setup and run scripts
    /// were told to bind.
    ///
    /// `title` is nothing for every menu that calls this, and something only when a caller knows
    /// what the pane is for: `pane_open` and `pane_split` carry the name an agent gave, because
    /// four tabs called Terminal are four a reader cannot tell apart. Nil takes the numbering each
    /// kind has always had, so no menu changed when this argument arrived.
    static func open(
        _ kind: PaneKind,
        in model: WorkspaceModel,
        url: String = "",
        title: String? = nil,
        place: @escaping @MainActor (PaneContent) -> Void
    ) {
        switch kind {
        case .chat:
            Task {
                guard let session = await model.createSession(title: title) else { return }
                place(.chat(session.id))
            }

        // The shell itself is not started here. `ToolPaneView` settles the environment and the
        // port first, because both are baked into the process the moment it is forked.
        case .terminal:
            let tab = CenterTabStore.shared.add(
                kind: .terminal, workspaceID: model.workspace.id, title: title
            )
            place(.tool(tab.id))

        case .browser:
            let tab = CenterTabStore.shared.add(
                kind: .browser, workspaceID: model.workspace.id, url: url, title: title
            )
            place(.tool(tab.id))
        }
    }
}
