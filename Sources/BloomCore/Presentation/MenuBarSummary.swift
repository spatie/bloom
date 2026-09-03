import Foundation

/// What the menu bar item says without being opened, and what the menu under it lists.
///
/// The whole reason to live in the menu bar is the glance: if the answer needs a click it might as
/// well have stayed in the Dock. So the item carries the numbers themselves, and this decides
/// which of them are worth the width.
///
/// In the core rather than beside the status item, so the wording, the arithmetic and the three
/// filters the menu is built from can be tested against fixtures rather than read off a strip of
/// menu bar that cannot be screenshotted.
public enum MenuBarSummary {
    /// One number and the glyph that says what it counts.
    public struct Segment: Equatable, Sendable {
        /// An SF Symbol name. The same two the sidebar draws, so the strip and the list agree.
        public let symbolName: String
        public let count: Int
        /// For VoiceOver, and for the attachment's accessibility description.
        public let label: String

        public init(symbolName: String, count: Int, label: String) {
            self.symbolName = symbolName
            self.count = count
            self.label = label
        }
    }

    /// The glyph for an agent blocked on a question. The same raised hand `WorkspaceStatusGlyph`
    /// draws, so the strip and the sidebar say the same thing with the same shape.
    public static let waitingSymbol = "hand.raised.fill"
    /// The glyph for an agent mid turn. `WorkspaceStatusGlyph` and the Dock menu use the same one.
    /// Only the menu's rows now, not the strip: see `segments`.
    public static let runningSymbol = "circle.fill"
    /// The glyph for a workspace that finished something nobody has read.
    public static let unreadSymbol = "envelope.fill"

    /// What to draw beside the mark, in reading order.
    ///
    /// Empty when there is nothing to report, which leaves the item as the mark alone. A zero is
    /// not news, for the same reason the Dock badge is cleared rather than zeroed, and a menu bar
    /// is the most expensive strip of screen in the system to spend on saying nothing.
    ///
    /// Waiting comes first because it is the only one that costs anything to ignore: a blocked
    /// agent is a paid process doing nothing. Unread is second because it is already settled and
    /// will keep.
    ///
    /// **Agents running are deliberately not here.** They were, drawn between the two, and at menu
    /// bar size a filled circle and a filled hand are two dark blobs of the same weight: the owner
    /// could not tell the running count from the waiting one, which cost him the only number that
    /// is expensive to miss. Redrawing the glyphs to fight less was the other way out; taking one
    /// away is the better one, because a hand beside an envelope are different silhouettes and
    /// because a running count is not a thing anyone acts on. Which workspaces are working is
    /// still in the menu, by name, which is a more useful answer than the number ever was.
    public static func segments(waiting: Int, unread: Int) -> [Segment] {
        var segments: [Segment] = []
        if waiting > 0 {
            segments.append(
                Segment(symbolName: waitingSymbol, count: waiting, label: "Agents waiting on you")
            )
        }
        if unread > 0 {
            segments.append(
                Segment(symbolName: unreadSymbol, count: unread, label: "Unread results")
            )
        }
        return segments
    }

    /// The hover text, which is where the glyphs get explained. Two numbers next to two small
    /// shapes are learnable but not self-evident the first time.
    public static func tooltip(waiting: Int, unread: Int) -> String {
        var lines: [String] = []
        if waiting > 0 {
            lines.append("\(Counted.of(waiting, "agent")) waiting on you")
        }
        if unread > 0 {
            lines.append(Counted.of(unread, "unread result"))
        }
        return lines.isEmpty ? idleTooltip : lines.joined(separator: ", ")
    }

    /// The limits panel read out loud.
    ///
    /// A disabled menu item carrying a custom view has no title for VoiceOver to speak and a
    /// hosted SwiftUI subtree is a stack of unlabelled shapes, so the whole row is labelled with
    /// one sentence instead. Here rather than beside the panel because it is the only version of
    /// that panel anything in `Tests/BloomCoreTests` can hold still.
    ///
    /// It says limit rather than allowance because the panel does, and the two have to agree: a
    /// heading a sighted reader sees as LIMITS and a screen reader announces as an allowance is
    /// two names for one row.
    public static func limitSentence(for board: QuotaBoard, at now: Date = Date()) -> String {
        guard let headline = board.headline, let fraction = headline.fraction else {
            return board.isEmpty
                ? "No limit reported yet"
                : "Limits reported, none of them measured yet"
        }
        let percentage = Int((min(max(fraction, 0), 1) * 100).rounded(.down))
        var sentence = "\(headline.provider.label), \(headline.window.label.lowercased()) "
            + "limit \(percentage) percent used"
        if let resetsAt = headline.resetsAt {
            sentence += ", lifts \(QuotaCountdown.phrase(until: resetsAt, from: now))"
        }
        let others = board.all.count - 1
        if others > 0 {
            sentence += ". \(Counted.of(others, "other window"))"
        }
        return sentence
    }

    /// The hover text over a bare strip, and it is not `emptyTitle`.
    ///
    /// The strip no longer counts running agents, so it is blank with three of them mid turn, and
    /// a hover reading "No agents running" would be contradicted by the menu listing all three the
    /// moment it was clicked. What a bare strip actually means is that nothing needs a person.
    public static let idleTooltip = "Nothing waiting on you"

    /// The one disabled row shown when none of the lists has anything in it, so the menu is never
    /// an empty rectangle that looks broken.
    public static let emptyTitle = "No agents running"

    /// The heading over the workspaces whose agent is blocked on a question. First in the menu,
    /// because it is the only list where the rows are costing something.
    public static let waitingHeading = "Waiting on you"

    /// The heading over the workspaces with an agent mid turn.
    public static let runningHeading = "Running"

    /// The heading over the workspaces that finished something nobody has read.
    ///
    /// It read "Waiting for you", one preposition away from "Waiting on you" above it, and the two
    /// mean opposite things: one is an agent blocked and costing money, the other is a turn that
    /// ended and will keep. Nothing collided while `waitingHeading` had no section to head, and
    /// the first photograph of the menu with all three lists in it put the pair four rows apart.
    /// A menu is read at a glance, and a glance does not read prepositions.
    ///
    /// So "Finished", which borrows neither of the other headings' words. Not "Unread": the row
    /// underneath is a place to go rather than a message to mark as read, and that was the right
    /// half of the argument the old wording was built on.
    public static let unreadHeading = "Finished"

    /// One heading in the menu and the workspaces listed under it.
    public struct Section: Equatable, Sendable {
        public let heading: String
        /// The glyph on every row in the section, the same one the strip or the sidebar marks that
        /// state with, so a count and the rows it stands for are drawn alike.
        public let symbolName: String
        /// The accessibility description of that glyph, read one row at a time.
        public let label: String
        public let workspaces: [Workspace]

        public init(heading: String, symbolName: String, label: String, workspaces: [Workspace]) {
            self.heading = heading
            self.symbolName = symbolName
            self.label = label
            self.workspaces = workspaces
        }
    }

    /// The menu's lists, in the order they are drawn, with the empty ones left out.
    ///
    /// Here rather than beside the status item because this is where a bug lived. The menu used to
    /// be two filters written inline, and the local holding the second was called `waiting` while
    /// what it held was unread rows. The workspaces actually blocked on a question had no section
    /// at all: the strip counted one, and the menu that opened under it offered no way of finding
    /// out which workspace was asking. A filter written in a view is a decision nothing can test,
    /// so the three judgements live here, named after what they hold.
    ///
    /// `isRunning` and `isAwaitingPermission` are passed in for the reason `DockBadge` takes them:
    /// only the app layer knows, and it knows from the same observable sets the counts are read
    /// from, so the number in the strip and the list in the menu cannot disagree.
    ///
    /// Each workspace appears once, under the state the sidebar marks it with, because a row in
    /// two lists would contradict the single glyph beside it. `WorkspaceStatus` resolves waiting
    /// ahead of running, so running drops the blocked ones; unread is `DockBadge.hasUnreadResult`,
    /// called rather than restated, because the strip's number and the rows in the menu under it
    /// are one judgement and a rule written twice is a rule that can disagree with itself about one
    /// workspace. It needs no waiting term because a blocked agent is a running one.
    public static func sections(
        in workspaces: [Workspace],
        isRunning: (Workspace) -> Bool,
        isAwaitingPermission: (Workspace) -> Bool
    ) -> [Section] {
        var sections: [Section] = []

        let waiting = workspaces.filter(isAwaitingPermission)
        if !waiting.isEmpty {
            sections.append(Section(
                heading: waitingHeading,
                symbolName: waitingSymbol,
                label: "Agent waiting on you",
                workspaces: waiting
            ))
        }

        let running = workspaces.filter { isRunning($0) && !isAwaitingPermission($0) }
        if !running.isEmpty {
            sections.append(Section(
                heading: runningHeading,
                symbolName: runningSymbol,
                label: "Agent running",
                workspaces: running
            ))
        }

        let unread = workspaces.filter { DockBadge.hasUnreadResult($0, isRunning: isRunning) }
        if !unread.isEmpty {
            sections.append(Section(
                heading: unreadHeading,
                symbolName: unreadSymbol,
                label: "Unread",
                workspaces: unread
            ))
        }

        return sections
    }
}
