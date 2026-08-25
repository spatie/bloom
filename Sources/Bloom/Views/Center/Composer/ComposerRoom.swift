import SwiftUI
import Observation

/// How much room the composer has been given, held where changing it costs the composer rather
/// than everything beside it.
///
/// The number itself is not new and neither is what it is for: the divider between a conversation
/// and the box under it can only be dragged so far, and what stops it is how tall the pane is. It
/// used to be `@State` in `ChatPaneView`, passed down as a parameter, and that is the part this
/// type exists to change. A parameter is read by the view that PASSES it, so every change to it
/// re-ran the pane's body and rebuilt the whole transcript subtree beside the composer, to move a
/// clamp on a box the transcript knows nothing about.
///
/// It moves whenever the composer's own text rewraps, which during a window resize is most frames:
/// the editor grows a line, the chrome under it is measured again, the pane publishes a new height
/// and the transcript is rebuilt. Measured on a release build at 1440 by 900 over a 1,582 row
/// chat, a centre column layout pass is 11.1ms, and a resize asks for two or three of them a
/// frame.
///
/// So the value is handed down as an object instead. The identity never changes, so a pane holding
/// one takes no dependency on the height at all; only `ComposerView`, which reads `height` inside
/// its own body, is invalidated when the room changes. This is the same bargain `TranscriptBubbleWidth`
/// and `TranscriptHoverHost` make next door, and for the same reason: observation is recorded
/// where a property is READ.
@MainActor
@Observable
final class ComposerRoom {
    /// The height the transcript and the composer share, already quantised by `PaneMeasure.room`.
    /// Nought until the pane has been laid out, which `ComposerView` reads as "no cap yet".
    var height: CGFloat = 0
}
