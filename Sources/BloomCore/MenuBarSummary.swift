import Foundation

/// What the menu bar item says without being opened.
///
/// The whole reason to live in the menu bar is the glance: if the answer needs a click it might as
/// well have stayed in the Dock. So the item carries the two numbers themselves, and this decides
/// which of them are worth the width.
///
/// In the core rather than beside the status item, so the wording and the arithmetic can be tested
/// against fixtures rather than read off a strip of menu bar that cannot be screenshotted.
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

    /// The glyph for an agent mid turn. `WorkspaceStatusGlyph` and the Dock menu use the same one.
    public static let runningSymbol = "circle.fill"
    /// The glyph for a workspace that finished something nobody has read.
    public static let unreadSymbol = "envelope.fill"

    /// What to draw beside the mark, in reading order.
    ///
    /// Empty when there is nothing to report, which leaves the item as the mark alone. A zero is
    /// not news, for the same reason the Dock badge is cleared rather than zeroed, and a menu bar
    /// is the most expensive strip of screen in the system to spend on saying nothing.
    ///
    /// Running comes first because it is the thing still changing. Unread is already settled and
    /// will wait.
    public static func segments(running: Int, unread: Int) -> [Segment] {
        var segments: [Segment] = []
        if running > 0 {
            segments.append(
                Segment(symbolName: runningSymbol, count: running, label: "Agents running")
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
    public static func tooltip(running: Int, unread: Int) -> String {
        var lines: [String] = []
        if running > 0 {
            lines.append(running == 1 ? "1 agent running" : "\(running) agents running")
        }
        if unread > 0 {
            lines.append(unread == 1 ? "1 unread result" : "\(unread) unread results")
        }
        return lines.isEmpty ? emptyTitle : lines.joined(separator: ", ")
    }

    /// The one disabled row shown when neither list has anything in it, so the menu is never an
    /// empty rectangle that looks broken.
    public static let emptyTitle = "No agents running"

    /// The heading over the workspaces with an agent mid turn.
    public static let runningHeading = "Running"

    /// The heading over the workspaces that finished something nobody has read.
    ///
    /// "Waiting for you" rather than "Unread", because the row underneath is a place to go rather
    /// than a message to mark as read.
    public static let unreadHeading = "Waiting for you"
}
