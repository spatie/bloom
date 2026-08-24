import Foundation

/// Somewhere to keep a measurement the body does not read.
///
/// **A geometry probe writes once a frame, and `@State` turns every one of those writes into a
/// rebuild.** That is the right trade when the body actually draws the number, and it is pure
/// waste when it does not: `CenterPaneView` measures its own size so a drop closure can say which
/// quarter a tab was let go in, and `SessionTabsView` measures where each tab is centred so a drag
/// can take a snapshot when it begins. Neither number is drawn by anything. Kept in `@State` they
/// invalidated a pane, and a strip, on every frame of every window resize, for a value nobody was
/// going to look at until the pointer went down.
///
/// A class held in `@State` is the fix, because SwiftUI tracks the STATE and not what it points
/// at: the reference never changes, so writing through it is not a change SwiftUI can see. This is
/// the same reasoning `TranscriptGeometry` writes down from the other side, where the number IS
/// drawn and so is rounded instead. Reach for that one when the body reads the value and this one
/// when it does not.
///
/// Not `@Observable`, deliberately, and not because it was forgotten: observation is exactly the
/// thing being avoided here.
@MainActor
final class GeometryBox<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
