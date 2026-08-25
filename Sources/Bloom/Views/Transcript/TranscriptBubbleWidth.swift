import SwiftUI
import Observation

/// The width a speech bubble is allowed to fill, held where changing it costs one row rather than
/// the whole list.
///
/// It used to be a field of `TranscriptGeometry`, which is `@State` in `TranscriptListView`. That
/// file already explains why the number is quantised: a raw container width moves on every pixel
/// of a drag, and a `@State` that moves once a frame re-runs the list's body and with it the
/// `ForEach` over every row the lazy stack has realised. Quantising it to eight points cut that
/// from once a frame to once every eight points, which was the right fix for the drag it was
/// measured against and is still an order of magnitude too much for the gesture the owner
/// complained about next.
///
/// **Measured, on a release build at 1440 by 900, resizing a window holding a conversation of
/// 1,104 rows beside a browser with the changed files up:** four points of travel per frame steps
/// this value every other frame, and the centre column laid out 1,273 to 1,310 times over 480
/// steps, 7.5 to 8.7ms a pass. Nineteen percent of that resize was inside `ForEachChild.updateValue`,
/// which is SwiftUI rebuilding the row values of a list whose body had been invalidated, and six
/// percent of it was `ObservationCenter.invalidate` tearing down and re-registering the
/// observation each of those rebuilt rows had.
///
/// So the number is moved out of the value the list reads. This is the same bargain
/// `TranscriptHoverHost` writes down next door, and for the same reason: observation is recorded
/// where a property is READ during a body. The object's identity never changes, so the list and
/// every tool row can be handed it and read nothing; only a bubble reads `cap`, so only the
/// handful of bubbles on screen are invalidated when the pane is made narrower.
///
/// It stays quantised. Nothing about moving it here makes a per-pixel value cheap for the rows
/// that DO read it, and eight points is invisible on a bubble several hundred points wide.
@MainActor
@Observable
final class TranscriptBubbleWidth {
    /// Already rounded, by `TranscriptGeometry.cap`. See that type for why it is rounded down.
    var cap: CGFloat = 240
}

extension EnvironmentValues {
    /// Nil wherever no transcript is drawing bubbles, which is what the fallback in
    /// `UserTurnRowView` is for.
    @Entry var transcriptBubbleWidth: TranscriptBubbleWidth?
}
