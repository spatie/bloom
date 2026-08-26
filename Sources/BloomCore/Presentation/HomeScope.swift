import Foundation

/// The chips on Home's strip, and what each of them lets through.
///
/// **One rule where there were two.** Home had a search field and a "Hide archived" switch; the
/// Search screen had a field of its own, a second layout and a second keyboard model, and the
/// Archive screen listed the archived workspaces a third time. All three were the same question
/// asked of the same list, so they are one list with a scope on it now, and the scope is a value
/// rather than a screen.
///
/// **Two sets, because searching and browsing narrow different things.** Browsing, the chips cut
/// the rows by what is happening in them. Searching, they cut the answer by what kind of thing
/// matched: a name, or something an agent said. `all` is the resting value of both and is the
/// only case in both sets, which is what lets a search start and end without the scope having to
/// be remembered or reset by hand. See `settle(_:searching:)`.
public enum HomeScope: String, Hashable, Sendable, CaseIterable, Codable {
    /// No narrowing. "All" while browsing, "Everything" in a search, because in a search the
    /// count is over two kinds of result rather than over rows.
    case all
    /// Waiting on a person: an agent stopped to ask something, or a turn finished and nobody has
    /// read it.
    case needsYou
    /// An agent is mid turn right now.
    case running
    /// Still has a worktree on disk. This is what the old "Hide archived" switch was for, kept as
    /// a scope rather than as a switch of its own.
    case live
    /// Archived: readable, restorable, with nothing left on disk.
    case archived
    /// Search only: the workspaces whose name, branch or project matched.
    case workspaces
    /// Search only: the transcripts that matched.
    case transcripts

    /// The chips on offer, in the order they are drawn.
    ///
    /// **Browsing, there are two: `all` and `archived`.** There were five, and the three that went
    /// (`live`, `needsYou`, `running`) were each a true fact about the list drawn as a control.
    /// The owner asked for them to go, and the reason is visible in the strip they made: five
    /// chips across the top of the first screen he sees, of which he pressed one. A filter nobody
    /// reaches for is a row of words to read past.
    ///
    /// What is lost is real and worth naming rather than pretending away: **there is now no way to
    /// ask "which of these is waiting on me" from this strip.** The list still answers it, by the
    /// glyph on each row and by the order, and the sidebar answers it too. If that turns out not
    /// to be enough, `needsYou` is the one to bring back, because it is the only one of the three
    /// that asks something the list does not already show at a glance.
    ///
    /// Searching, `all` still leads and the two kind chips stay, because there the chips split an
    /// answer rather than narrowing a list nobody asked to narrow.
    public static func offered(searching: Bool) -> [HomeScope] {
        searching
            ? [.all, .workspaces, .transcripts, .archived]
            : [.all, .archived]
    }

    /// What the strip is set to when nothing has been asked of it.
    ///
    /// **Browsing, that is `all`, and it was `live` until the strip lost the chip for it.** A
    /// resting scope with no chip is a state you cannot see you are in and cannot leave, which is
    /// worse than either answer.
    ///
    /// The argument for `live` is still on the record and still true: on the machine this screen
    /// was redesigned against, `all` is twenty rows of which seventeen are archived, a page about
    /// the past in which the three workspaces that can still be acted on are outnumbered six to
    /// one. What stops that being the whole story is that an archived row is drawn quiet, the
    /// live ones carry a glyph, and the list is ordered by when it happened, so the top of `all`
    /// is the recent work whichever state it is in. If Home starts reading as a page about the
    /// past again, this is the line to change back.
    ///
    /// Searching, it is `all`: a search is a question about the whole machine, archived work
    /// included, and narrowing one by default would be answering a question that was not asked.
    public static func resting(searching: Bool) -> HomeScope {
        .all
    }

    public func label(searching: Bool) -> String {
        switch self {
        case .all: searching ? "Everything" : "All"
        case .needsYou: "Needs you"
        case .running: "Running"
        case .live: "Live"
        case .archived: "Archived"
        case .workspaces: "Workspaces"
        case .transcripts: "Transcripts"
        }
    }

    /// The scope to hold after the field has been typed into or emptied.
    ///
    /// A chip that is not on offer in the set now being drawn falls back to the resting scope
    /// rather than staying selected and invisible, which is how a list ends up showing nothing
    /// with no control on screen explaining why. `archived` survives the crossing in both
    /// directions, deliberately: somebody who narrowed to finished work and then typed a name is
    /// still asking about finished work.
    ///
    /// `live` crossing into a search becomes `all`, which is right rather than merely tidy: a
    /// search of live work alone would silently refuse to find the archived workspace somebody is
    /// searching for the name of.
    public static func settle(_ scope: HomeScope, searching: Bool) -> HomeScope {
        offered(searching: searching).contains(scope) ? scope : resting(searching: searching)
    }

    /// Whether workspace rows are drawn at all under this scope.
    public var showsWorkspaces: Bool { self != .transcripts }

    /// Whether transcript results are drawn under this scope. Only ever asked while searching.
    public var showsTranscripts: Bool {
        switch self {
        case .all, .transcripts, .archived: true
        default: false
        }
    }

    /// Whether one transcript result belongs in this scope.
    ///
    /// The `archived` chip is the one that has to ask. It means "finished work" rather than
    /// "finished workspaces", so it holds the transcripts of archived workspaces as well as their
    /// rows, and it must not carry through what a live workspace's agent said.
    public func includesTranscript(isArchived: Bool) -> Bool {
        switch self {
        case .archived: isArchived
        default: showsTranscripts
        }
    }

    /// Whether one row belongs in this scope.
    public func includes(_ row: HomeRow, activity: HomeActivity) -> Bool {
        switch self {
        case .all, .workspaces: true
        case .needsYou: activity.needsYou(row.workspace)
        case .running: activity.isRunning(row.workspace)
        case .live: !row.isArchived
        case .archived: row.isArchived
        case .transcripts: false
        }
    }
}

/// What an agent is doing in a workspace right now, which the row itself cannot say.
///
/// A row is a database record. Whether a turn is open, and whether it stopped to ask something,
/// live in the app's own memory and move without the record moving, so they are handed in rather
/// than read off the workspace. Two sets rather than two closures, so `HomeList.build` stays pure
/// and the suite can stand a machine with three agents running without an app around it.
public struct HomeActivity: Sendable, Equatable {
    public var running: Set<WorkspaceID>
    /// Blocked on a question from the agent.
    public var waiting: Set<WorkspaceID>

    public init(running: Set<WorkspaceID> = [], waiting: Set<WorkspaceID> = []) {
        self.running = running
        self.waiting = waiting
    }

    public func isRunning(_ workspace: Workspace) -> Bool {
        running.contains(workspace.id)
    }

    /// Waiting on a person: an agent has asked something, or a turn finished and nobody has read
    /// it.
    ///
    /// An archived workspace never counts, whatever its `unread` flag says. That flag is a
    /// leftover with nothing behind it once the worktree is gone, which is the rule
    /// `WorkspaceUnreadMark` already holds and this defers to rather than restating.
    public func needsYou(_ workspace: Workspace) -> Bool {
        guard workspace.state == .active else { return false }
        return waiting.contains(workspace.id) || WorkspaceUnreadMark.isUnread(workspace)
    }
}

/// What each chip counts, worked out in the same pass as the list.
///
/// Every chip carries its own number and they are counted over what the project filter and the
/// search left, never over what the SELECTED chip left, which is Finder's scope bar behaviour: a
/// count that changed when you clicked it would be a count of the thing you are already looking
/// at.
public struct HomeScopeCounts: Sendable, Equatable {
    public var needsYou = 0
    public var running = 0
    public var live = 0
    /// Archived work in the pane. Outside a search that is the archived rows; inside one it is
    /// those rows plus the transcript matches that came out of an archived workspace, so it is in
    /// the same units as `all` and the two chips can be read against each other.
    public var archived = 0
    /// Workspace rows that matched, which is the "Workspaces" chip in a search.
    public var workspaces = 0
    /// Transcript matches, summed over every workspace, which is the "Transcripts" chip.
    public var transcripts = 0
    /// How many workspaces those matches are spread over, which is the other half of the heading
    /// above the transcript results.
    public var transcriptWorkspaces = 0

    public init() {}

    /// The number a chip draws, or nothing at all.
    ///
    /// **A nought is not a number worth printing.** The resting strip on a quiet machine read
    /// "Needs you 0, Running 0", which is two facts stated in the least useful way there is: they
    /// are the state most of the time, so the noughts are what the eye learns to skip, and the
    /// numbers beside them get skipped with them. Bare, the chip says the same thing by saying
    /// nothing, and a number arriving on it is itself the signal.
    ///
    /// The chip stays on the strip either way. Dropping it would reflow the row every time an
    /// agent started or stopped, which is movement under the pointer for no gain.
    /// **Only the two chips whose number is a size, and not the three whose number is a state.**
    /// Live, Needs you and Running each carried one too, and five numbers across one strip is a row
    /// of figures to read rather than a set of filters to press. The two that keep theirs are the
    /// ones where the number is the point: All says how much there is, and Archived says how much
    /// of it is behind you. Live is answered by the list underneath it, and the whole argument
    /// below about a nought being worth nothing applies twice over to a three.
    public func badge(of scope: HomeScope, searching: Bool) -> Int? {
        guard scope == .all || scope == .archived else { return nil }
        let value = count(of: scope, searching: searching)
        return value == 0 ? nil : value
    }

    /// What one chip says. `all` is the sum of the two kinds in a search and the whole list
    /// outside one.
    public func count(of scope: HomeScope, searching: Bool) -> Int {
        switch scope {
        case .all: searching ? workspaces + transcripts : live + archived
        case .needsYou: needsYou
        case .running: running
        case .live: live
        case .archived: archived
        case .workspaces: workspaces
        case .transcripts: transcripts
        }
    }
}
