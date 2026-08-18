import Foundation

/// What the transcript needs to know about the space it is being drawn in.
///
/// Both values come from one `onScrollGeometryChange` subscription rather than from a
/// `GeometryReader` and a preference key: the scroll view already knows its container size, its
/// content size and where it sits between them, and asking it directly is both cheaper and immune
/// to the "the probe stopped being built" edge cases a preference-based measurement has.
struct TranscriptGeometry: Equatable {
    var width: CGFloat = 0
    /// Whether the user is close enough to the newest row to count as following along.
    var isNearBottom = true
}
