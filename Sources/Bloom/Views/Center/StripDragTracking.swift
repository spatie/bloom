import SwiftUI
import BloomCore

/// What one tab of the strip has to report for the strip to move its tabs out from under the
/// pointer: where it is, and when a drag of it starts and stops.
///
/// A modifier rather than three lines repeated on each of the two kinds of tab, because they have
/// to agree exactly. A conversation and a tool tab are drawn by different functions, and a
/// measurement taken in one space with a pointer reported in another would put every tab of one
/// kind at the wrong place.
///
/// `onDragSessionUpdated` is the only thing that says WHICH tab a drag is carrying while it is in
/// flight. The drop tells us at the end, and by then it is too late to have moved anything. A drop
/// session carries no payload either, so a strip watching only the pointer would know that
/// something was being dragged over it and not what.
struct StripDragTracking: ViewModifier {
    /// Which tab this is, in the one type that can name a conversation and a tool tab without
    /// throwing away which of the two it is. A bare string would be both an id of no particular
    /// kind and, in an unsplit tab, the same string as a pane's.
    var content: PaneContent
    /// The space the strip measures in, which is the row of tabs itself, so a measurement and a
    /// pointer position cannot drift apart when the row is scrolled.
    var space: String
    var onMeasure: (Double) -> Void
    var onBegin: () -> Void
    /// Told whether the drag was taken by something or thrown away. A tab let go over a pane is
    /// taken, and the strip never hears about the drop, so the preview has to be settled from here
    /// or it would sit there for good.
    var onEnd: (Bool) -> Void

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: Double.self) { proxy in
                proxy.frame(in: .named(space)).midX
            } action: {
                onMeasure($0)
            }
            // Which end of a drag gets there first is not something to depend on. The strip's own
            // drop and this both settle the preview, and whichever arrives second finds nothing
            // pending. `.ending` is unavailable on macOS, so a drag is over at `.ended`.
            .onDragSessionUpdated { session in
                switch session.phase {
                case .initial, .active:
                    onBegin()
                case .ended(let operation):
                    onEnd(operation != .cancel && operation != .forbidden)
                case .dataTransferCompleted:
                    onEnd(true)
                default:
                    return
                }
            }
    }
}
