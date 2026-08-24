import Foundation

/// What a tool row is saying about itself, before anybody decides what colour that is.
///
/// `ToolPresentation.tint` was a SwiftUI `Color`, and that one field is what kept the presenter
/// and every decision in it inside the app target, where `Tests/BloomCoreTests` cannot reach.
/// Thirty-odd tool cases each pick one of exactly five of these, so the choosing is a decision
/// with five answers and the colouring is a drawing with one line per answer.
///
/// Five and not more, deliberately. The transcript is hundreds of one-line rows and a palette that
/// grows a colour per tool stops being a code and becomes decoration; a closed set is also what
/// makes a new tool's row look like the rows around it rather than like a new thing.
public enum ToolTint: String, Sendable, Hashable, CaseIterable {
    /// It read something, or did something with no outcome worth colouring.
    case neutral
    /// It is Bloom's own doing, or a search this window will show the results of.
    case accent
    /// It made or changed something.
    case positive
    /// It failed, or it is destroying something.
    case negative
    /// It is asking, waiting, or doing something worth watching.
    case warning
}
