import SwiftUI

/// One tool call compressed to the single line a collapsed transcript row shows.
///
/// The whole transcript design rests on this: an agent run is hundreds of actions, and the only way
/// to watch one is if every action costs exactly one line. So a presentation is a glyph, a short
/// label that names the intent, and a dimmed detail that names the target. Nothing here is ever raw
/// JSON, because a wall of braces is the thing this view exists to avoid.
struct ToolPresentation: Equatable {
    /// An SF Symbol name.
    var glyph: String
    var label: String
    var detail: String
    var tint: Color
    var chips: [String] = []
}
