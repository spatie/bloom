import Foundation

/// What the menu bar item says without being opened.
///
/// The whole reason to live in the menu bar is the glance: if the answer needs a click it might as
/// well have stayed in the Dock. So the item carries the numbers themselves, and this decides
/// which of them are worth the width.
///
/// In the core rather than beside the status item, so the wording and the arithmetic can be
/// tested against fixtures rather than read off a strip of menu bar that cannot be screenshotted.
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
            lines.append(waiting == 1 ? "1 agent waiting on you" : "\(waiting) agents waiting on you")
        }
        if unread > 0 {
            lines.append(unread == 1 ? "1 unread result" : "\(unread) unread results")
        }
        return lines.isEmpty ? idleTooltip : lines.joined(separator: ", ")
    }

    /// The hover text over a bare strip, and it is not `emptyTitle`.
    ///
    /// The strip no longer counts running agents, so it is blank with three of them mid turn, and
    /// a hover reading "No agents running" would be contradicted by the menu listing all three the
    /// moment it was clicked. What a bare strip actually means is that nothing needs a person.
    public static let idleTooltip = "Nothing waiting on you"

    /// The one disabled row shown when neither list has anything in it, so the menu is never an
    /// empty rectangle that looks broken.
    public static let emptyTitle = "No agents running"

    /// The heading over the workspaces whose agent is blocked on a question. First in the menu,
    /// because it is the only list where the rows are costing something.
    public static let waitingHeading = "Waiting on you"

    /// The heading over the workspaces with an agent mid turn.
    public static let runningHeading = "Running"

    /// The heading over the workspaces that finished something nobody has read.
    ///
    /// "Waiting for you" rather than "Unread", because the row underneath is a place to go rather
    /// than a message to mark as read.
    public static let unreadHeading = "Waiting for you"
}
