import Foundation

/// A workspace's tab strip, as `workspace_tabs` reports it.
///
/// **The other way round from `PaneCensus`, deliberately.** That one flattens a workspace into
/// panes, because the question the browser tools ask first is "which of the reader's browsers do
/// you mean" and a browser is a pane wherever it is sitting. This one is the strip itself: one
/// entry per tab, left to right, with what a tab has absorbed into a split hanging off it. A model
/// asked to bring a tab forward has to be able to name a tab, and a flat list of panes has nothing
/// in it that is a tab.
///
/// The two are not a hierarchy and neither replaces the other. They report the same window through
/// the same walk (`WorkspaceTabsStore.entries` and the layout under each), so a browser has the
/// same number in both, which is what lets `workspace_tabs` be the only call a turn needs before
/// it reaches for `browser_read`.
public struct WorkspaceTabCensus: Sendable, Equatable {
    public var tabs: [WorkspaceTabReport]

    public init(tabs: [WorkspaceTabReport]) {
        self.tabs = tabs
    }

    /// What the tool answers with.
    public var json: JSONValue {
        .object([
            "tabs": .array(tabs.map(\.json)),
            "count": .integer(tabs.count),
            "note": .string(note),
        ])
    }

    /// What the answer says about itself.
    ///
    /// Two facts a model cannot get from the list. The first is that the numbers are positions
    /// rather than identities, which is the same warning `BrowserPaneReport.number` carries and is
    /// worth repeating in the answer rather than only in the description: a description is read
    /// once when the tools are listed and this is read in the turn the numbers are being acted on.
    /// The second only appears when there is a browser, and it is `PaneCensus.browserNote` word for
    /// word, because a tab named after a page is page-written text either way it is reported.
    public var note: String {
        var sentences: [String] = []

        if tabs.isEmpty {
            sentences.append(
                "That workspace has nothing open in the centre column at the moment, which "
                    + "usually means Bloom has not finished reading its chats yet."
            )
        } else {
            sentences.append(
                "'tab' is a place in the strip counting from 1, not an identity: it changes when "
                    + "a tab is opened, closed or dragged. Call workspace_tabs again before "
                    + "acting on a number you have been holding."
            )
        }

        // A browser absorbed into a pane of another tab is still a browser whose name came off a
        // page, so the panes are looked at as well as the roots.
        let hasBrowser = tabs.contains { tab in
            tab.kind == .browser || tab.panes.contains { $0.kind == .browser }
        }
        if hasBrowser { sentences.append(PaneCensus.browserNote) }

        return sentences.joined(separator: " ")
    }
}

/// One tab of the strip.
public struct WorkspaceTabReport: Sendable, Equatable {
    /// Where it sits in the strip, counting from 1. **Not the tab's id**, which is a uuid: see
    /// `BrowserPaneReport.number`, which argues that choice at length for the same window and is
    /// the reason the two tools hand out the same kind of handle.
    ///
    /// It is the number of the tabs that are reported rather than of the entries that were walked,
    /// so a strip entry pointing at a chat that has just been archived cannot leave a gap in the
    /// count and send `workspace_tab_select` one tab off.
    public var number: Int
    /// What the strip calls it, which is what the reader would say to name it out loud, and what
    /// `workspace_tab_select` takes as `title`.
    public var title: String
    /// Whether this is the tab in front. Exactly one tab of a workspace is.
    public var isActive: Bool
    /// What is at the root of the tab, and the one true thing about it worth reporting.
    public var detail: WorkspaceTabDetail
    /// What else this tab has absorbed, when it is split. Empty for a tab nobody has divided,
    /// which is nearly all of them.
    public var panes: [WorkspaceTabPane]

    public init(
        number: Int,
        title: String,
        isActive: Bool,
        detail: WorkspaceTabDetail,
        panes: [WorkspaceTabPane] = []
    ) {
        self.number = number
        self.title = title
        self.isActive = isActive
        self.detail = detail
        self.panes = panes
    }

    /// Derived rather than stored beside `detail`, so the word and the block under it cannot come
    /// to disagree about what a tab is.
    public var kind: PaneCensusKind { detail.kind }

    public var json: JSONValue {
        var fields: [String: JSONValue] = [
            "tab": .integer(number),
            "kind": .string(kind.rawValue),
            "title": .string(title),
            "active": .bool(isActive),
        ]
        fields[kind.rawValue] = detail.json
        if !panes.isEmpty {
            fields["split_into"] = .array(panes.map(\.json))
        }
        return .object(fields)
    }
}

/// What is in a tab, one case per kind, each carrying only what Bloom already knows.
///
/// **Nothing here costs a subprocess or a request.** That is the rule the cases were chosen
/// against rather than a happy accident: a terminal says which directory its shell was started in
/// and not what is running in it, because the second answer means asking tmux, and a listing that
/// shells out is a listing that can hang the turn that called it. A browser says what the toolbar
/// says and never what the page says, which is the line `BridgeToolApproval` draws for the whole
/// family.
public enum WorkspaceTabDetail: Sendable, Equatable {
    case chat(WorkspaceTabChat)
    case terminal(WorkspaceTabTerminal)
    /// The browser's own chrome, reusing what `pane_list` and `browser_read` report, so the number
    /// in this listing is the number the six `browser_` tools take.
    case browser(BrowserPaneReport)
    case review(WorkspaceTabReview)
    case notes(WorkspaceTabNote)

    public var kind: PaneCensusKind {
        switch self {
        case .chat: .chat
        case .terminal: .terminal
        case .browser: .browser
        case .review: .review
        case .notes: .notes
        }
    }

    public var json: JSONValue {
        switch self {
        case .chat(let chat): chat.json
        case .terminal(let terminal): terminal.json
        case .browser(let browser): browser.json
        case .review(let review): review.json
        case .notes(let note): note.json
        }
    }
}

/// A conversation tab: which agent, what it is doing, and how much of it there is.
public struct WorkspaceTabChat: Sendable, Equatable {
    public var agent: AgentKind
    /// The `sessions` row's own column, which is the honest source: the runner writes it on every
    /// change and `Store.resetRunningSessions` clears it at launch, so a row left `running` by a
    /// crash cannot claim an agent that is long gone. Same reading `workspace_list` reports.
    public var state: SessionState
    public var messages: Int

    public init(agent: AgentKind, state: SessionState, messages: Int) {
        self.agent = agent
        self.state = state
        self.messages = messages
    }

    /// `running` is emitted beside `state` rather than left to be derived, because the one thing a
    /// caller acts on is whether a turn is going, and `waiting` is the case that reads wrong: the
    /// process is alive and no work is happening, which is the opposite of running rather than a
    /// shade of it. See `SessionState.waiting`.
    public var json: JSONValue {
        .object([
            "agent": .string(agent.rawValue),
            "state": .string(state.rawValue),
            "running": .bool(state == .running),
            "messages": .integer(messages),
        ])
    }
}

/// A terminal tab, as much of one as Bloom knows without asking a shell anything.
public struct WorkspaceTabTerminal: Sendable, Equatable {
    /// Where its shell was started, which is the workspace's worktree. Bloom does not follow a
    /// `cd`: reading a live working directory means asking tmux or walking `/proc`, and neither
    /// belongs in a listing.
    public var directory: String
    /// Whether a shell has actually been forked for it in this run of Bloom.
    ///
    /// False is the ordinary answer rather than the exceptional one. A workspace reopened this
    /// morning has every terminal tab it had last night and none of them has a shell until
    /// somebody clicks it, which is the same distinction `BrowserPaneReport.isLive` draws.
    public var isLive: Bool

    public init(directory: String, isLive: Bool) {
        self.directory = directory
        self.isLive = isLive
    }

    public var json: JSONValue {
        .object([
            "directory": .string(directory),
            "live": .bool(isLive),
            "note": .string(
                isLive
                    ? "Bloom knows where this shell was started, not what is running in it now."
                    : "Nobody has opened this tab in this run of Bloom, so no shell has been "
                        + "started for it yet."
            ),
        ])
    }
}

/// The workspace's one review tab, and the file it is reading.
///
/// One per workspace, always, which is why there is nothing here to tell two of them apart: see
/// the note on `CenterTab`, where the decision not to open a tab per file is argued.
public struct WorkspaceTabReview: Sendable, Equatable {
    /// The file under the cursor, relative to the worktree, or empty for the whole change.
    public var file: String

    public init(file: String) {
        self.file = file
    }

    public var json: JSONValue {
        var fields: [String: JSONValue] = [:]
        if file.isEmpty {
            fields["showing"] = .string("all changes")
        } else {
            fields["file"] = .string(file)
        }
        fields["note"] = .string(
            "The diff itself is not here. The worktree is an ordinary git checkout, so read it "
                + "with your own tools."
        )
        return .object(fields)
    }
}

/// The workspace's one notes tab.
///
/// A length and not the text. The note is the reader's own writing about the work, it is not
/// addressed to an agent, and a listing that carried it would put it into a model's context every
/// time anybody asked what was open. The length is enough to answer the only question a caller has
/// about it, which is whether there is anything there.
public struct WorkspaceTabNote: Sendable, Equatable {
    public var characters: Int

    public init(characters: Int) {
        self.characters = characters
    }

    public var json: JSONValue {
        .object([
            "characters": .integer(characters),
            "note": .string(
                characters == 0
                    ? "The note is empty."
                    : "The text of the note is the person's own and is not reported here."
            ),
        ])
    }
}

/// One pane of a split tab, named the way the strip would name it.
///
/// Smaller than `PaneCensusEntry` on purpose. This says what a tab has absorbed so that a caller
/// can see the arrangement and knows a browser is in there; everything else about those panes is
/// `pane_list`, which is the tool whose whole subject they are.
public struct WorkspaceTabPane: Sendable, Equatable {
    public var kind: PaneCensusKind
    public var title: String
    /// Browser panes only, and it is what the six `browser_` tools take.
    public var browser: Int?

    public init(kind: PaneCensusKind, title: String, browser: Int? = nil) {
        self.kind = kind
        self.title = title
        self.browser = browser
    }

    public var json: JSONValue {
        var fields: [String: JSONValue] = [
            "kind": .string(kind.rawValue),
            "title": .string(title),
        ]
        if let browser { fields["browser"] = .integer(browser) }
        return .object(fields)
    }
}
