import Foundation

/// How much air the conversation is given between its lines.
///
/// The owner asked for the line height to be a setting, with what had just landed as its default.
/// So 1.7 stopped being the answer and became the middle of five, and the five ratios below are
/// the whole of that decision. They are here rather than beside the picker for the reason the
/// three-target split exists: a number chosen inside a view is a number nothing can test.
///
/// **Named steps rather than a slider or a raw ratio.** That is `ChatTextSize`'s argument and it
/// holds again here. A ratio is not something a reader has in their hand: what they can judge is
/// the paragraph in front of them, and 1.85 is not a figure anybody would be able to name again
/// after closing the window. A fixed set of steps is also its own bounds and its own way back,
/// which is what makes "Default" a place on the control rather than a number to remember.
///
/// **Five of them, fifteen hundredths apart, and that spacing is what makes the control do
/// anything at all.** `TextLeading.overPointSize` rounds to a whole point, so two ratios that
/// round to the same number of points are one step wearing two labels. Resolved against the body
/// rung at each of the five chat text sizes, these five answer, in points added to the line box:
///
///     size / box   1.40  1.55  1.70  1.85  2.00
///     12 / 15        2     4     5     7     9
///     13 / 16        2     4     6     8    10
///     15 / 18        3     5     8    10    12
///     17 / 20        4     6     9    11    14
///     20 / 23        5     8    11    14    17
///
/// Every step differs from its neighbour at every text size, by two points at the default one.
/// A tenth apart would have collapsed rows of that table onto each other, which is a picker whose
/// middle segments do nothing; a fifth apart would have put the ends outside the range worth
/// offering. `ChatLineHeightTests` is that table, so a ratio cannot be nudged without the
/// collapse being noticed.
///
/// **The ends are where they are because of what is either side of them.** 1.4 is a dense
/// paragraph that fits more of a long answer on a screen, and it is under the 1.5 that WCAG 1.4.12
/// names for body text: tighter than this is not a preference any more, it is a paragraph that is
/// hard to read, and it is offered only because the reader has to ask for it by name. 2.0 is the
/// loosest a column of a chat pane's measure still reads as one block of text; past it the lines
/// stop belonging to each other.
///
/// **Deliberately not in the View menu.** Text size is there because Zoom In and Zoom Out are
/// reached several times in a session and macOS has a standing pair of keys for them. A line
/// height is set once, looked at, and left. Three more items in View, or a second pair of keys for
/// `TextZoom` to route between a terminal and a chat, would be menu weight for something nobody
/// opens a menu for twice.
public enum ChatLineHeight: String, CaseIterable, Identifiable, Sendable {
    case tightest
    case tighter
    case standard
    case looser
    case loosest

    /// The same `UserDefaults` slot the settings picker binds to. See `current`.
    public static let defaultsKey = "chat.lineHeight"

    public var id: String { rawValue }

    /// What a line of prose comes to, as a multiple of the size it is set at.
    ///
    /// Against the point size rather than against the line box, because that is how every
    /// stylesheet states a line height and it is the number the page this was drawn from was set
    /// with. See `TextLeading`, which holds both denominators and the reason there are two.
    public var ratio: Double {
        switch self {
        case .tightest: 1.4
        case .tighter: 1.55
        case .standard: 1.7
        case .looser: 1.85
        case .loosest: 2
        }
    }

    /// Comparatives rather than adjectives, so the control says which way each segment moves and
    /// where the range stops. "Tight" and "Relaxed" next to each other read as two named densities
    /// with no order between them; these cannot.
    public var title: String {
        switch self {
        case .tightest: "Tightest"
        case .tighter: "Tighter"
        case .standard: "Default"
        case .looser: "Looser"
        case .loosest: "Loosest"
        }
    }
}

extension ChatLineHeight {
    /// Read and written outside SwiftUI. `@AppStorage` keeps a raw-value enum as its raw string,
    /// so this is the same slot the settings picker binds to, and every open window follows a
    /// change to it at once.
    ///
    /// `ChatTextSize` has this because the View menu writes it. Nothing writes this one yet, on
    /// purpose: see the note above about why the line height stayed out of that menu. It is here
    /// because a setting with a `defaultsKey` and no way to read it from outside a view is half a
    /// setting, and because the first thing anybody adds here (a Reset, a probe, an offscreen
    /// render at a named step) would otherwise reach for `UserDefaults` by hand and spell the
    /// fallback differently.
    public static var current: ChatLineHeight {
        get {
            UserDefaults.standard.string(forKey: defaultsKey)
                .flatMap(ChatLineHeight.init(rawValue:)) ?? .standard
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}
