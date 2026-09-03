import BloomCore
import SwiftUI

/// Everything a transcript row needs that it cannot inherit, carried across the AppKit gap by
/// name.
///
/// **An `NSHostingView` built inside a coordinator is not a child of anything in SwiftUI's tree**,
/// so it inherits none of the values the pane above it set. The spike answered that with
/// `@Environment(\.self)` and re-applied the whole environment to every hosted row, which works
/// and is the wrong shape twice over.
///
/// It is the opposite of the narrowing the two objects below exist for. `TranscriptBubbleWidth`
/// and `TranscriptHoverHost` were each lifted out of the list's own state precisely so that a
/// value moving invalidates the handful of views that read it rather than the whole list; taking
/// `\.self` puts an edge on every environment value there is back on the list, so anything at all
/// changing anywhere in the environment re-runs the pass that assembles the entries. And it is why
/// a bubble cap written once per frame re-laid out every bubble on screen: with the whole
/// environment carried by hand, a write to the cap was a change to the value the table was handed.
///
/// So this is the list, and there is nothing else in it. Each line is here because a view under
/// `TranscriptRowView`, `TurnFooterView`, `UserTurnRowView`, `PendingTurnRowView` or
/// `WorkspaceEventsView` reads it:
///
/// - `app` for `ToolRowHeader`, `UserTurnRowView`, `ReviewTurnChips` and `WorkspaceEventsView`,
///   each of which asks the model something about the workspace the row belongs to.
/// - `hoverHost` and `bubbleWidth`, the two objects above. Identities, never values, so handing
///   them down costs a row nothing: see the headers of both.
/// - `linkActions` for what a link inside a row's markdown does when it is pressed or chosen from
///   a menu. Equatable on its values, which is what keeps a fresh struct per pass from counting
///   as a change.
/// - `fontScale`, `chatFont` and `chatLineHeight`, set by `ChatPaneView` from the reader's own
///   appearance settings. Nothing under a row reads a setting; they all read these.
/// - `reduceMotion`, which is the one value here that is carried and **not** applied.
///   `EnvironmentValues.accessibilityReduceMotion` is read-only, so it cannot be handed down like
///   the rest; a hosting view resolves it from the system, which is where it comes from anyway.
///   It is in this struct for the two things that do need it: `TranscriptTable` reads it to decide
///   how long a fold takes, and a change of it has to rebuild every cell, which is what carrying
///   it through the equality below buys.
///
/// What is deliberately NOT here: `\.colorScheme` and the rest of the appearance, which AppKit
/// resolves from the window's own `effectiveAppearance` for any hosting view inside it;
/// `\.openURL`, which `MarkdownView` sets for itself through `opensTranscriptLinks`;
/// `\.markdownIsStreaming`, which `MarkdownView` also sets for itself; and `\.openInRepoID`,
/// which only the inspector and the composer read. A value that turns out to be missing belongs
/// on this list with a line saying which view reads it, never back behind `\.self`.
struct TranscriptRowEnvironment: Equatable {
    let app: AppModel
    let hoverHost: TranscriptHoverHost
    let bubbleWidth: TranscriptBubbleWidth
    let linkActions: TranscriptLinkActions
    let fontScale: CGFloat
    let chatFont: ChatFont
    let lineHeight: ChatLineHeight
    let reduceMotion: Bool

    /// Identity for the three objects and value for the rest.
    ///
    /// The objects are shared for their whole lifetime, so comparing them by identity is the
    /// question actually being asked: has this row been handed a different host, not has the
    /// pointer inside it moved. Reading `cap` or `request` here would put the edge back that the
    /// whole arrangement exists to remove.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.app === rhs.app
            && lhs.hoverHost === rhs.hoverHost
            && lhs.bubbleWidth === rhs.bubbleWidth
            && lhs.linkActions == rhs.linkActions
            && lhs.fontScale == rhs.fontScale
            && lhs.chatFont == rhs.chatFont
            && lhs.lineHeight == rhs.lineHeight
            && lhs.reduceMotion == rhs.reduceMotion
    }

    /// Whether a row drawn in this environment can come out a different height from the same row
    /// drawn in the other one.
    ///
    /// **This is why switching workspaces was slow.** `linkActions` names the pane a link opens
    /// into, so it moves on every workspace switch and the switch counted as an environment
    /// change; an environment change emptied the whole height cache, so arriving at a conversation
    /// you had read a minute ago rebuilt an `NSHostingView` for every row in the window. What a
    /// link does when it is pressed cannot change how tall a paragraph is, and neither can a hover
    /// host or Reduce Motion. The text size, the typeface and the line height can, and a different
    /// list object means a different pane, so all of those keep their old answer.
    ///
    /// The line height is on this list because the owner made it a setting, and it is the one of
    /// the three that moves EVERY row: a step is points added to every line of every paragraph in
    /// the session. A cache not told about it hands the table the heights from the old step, and
    /// rows drawn from those overlap.
    ///
    /// The rule is here rather than in the core with the other decisions because it is about this
    /// type, and this type holds `AppModel` and a SwiftUI environment value. There is nothing for
    /// the core to hold.
    func wraps(differentlyFrom other: Self) -> Bool {
        fontScale != other.fontScale
            || chatFont != other.chatFont
            || lineHeight != other.lineHeight
            || app !== other.app
            || bubbleWidth !== other.bubbleWidth
    }
}

extension View {
    /// Puts a hosted transcript row back in the environment its pane would have given it.
    func transcriptRowEnvironment(_ values: TranscriptRowEnvironment) -> some View {
        environment(values.app)
            .environment(\.transcriptHoverHost, values.hoverHost)
            .environment(\.transcriptBubbleWidth, values.bubbleWidth)
            .markdownLinkActions(values.linkActions)
            .environment(\.fontScale, values.fontScale)
            .environment(\.chatFont, values.chatFont)
            .environment(\.chatLineHeight, values.lineHeight)
    }
}
