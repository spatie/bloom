import SwiftUI

/// A split view column whose reported size does not depend on what is inside it.
///
/// AppKit's split view asks each child for a minimum and a maximum size, and SwiftUI derives those
/// from whatever the hosting view contains. Put content in a column directly and its own intrinsic
/// minimum (a segmented control, a source list row, a merge button) becomes part of that report, so
/// the report changes every time the content does. AppKit answers each change with another Update
/// Constraints pass, and a column that also appears and disappears (the sidebar, the inspector) can
/// push the window past its pass limit, at which point AppKit throws
/// "more Update Constraints in Window passes than there are views in the window" and the app dies.
/// That crash was reproducible before this type existed: show and hide the inspector twice, or the
/// sidebar twice, and the window was gone.
///
/// Drawing the content in an `overlay` over an empty flexible container breaks the feedback loop.
/// An overlay is sized by what it is drawn on rather than the other way round, so the column
/// reports the same size whatever is inside it.
///
/// The ideal width has to be stated here rather than left to the content for the same reason. With
/// nothing to prefer, the inspector column stopped opening at its ideal width and took half the
/// window instead. The minimum and maximum still live where they belong, on
/// `navigationSplitViewColumnWidth` and `inspectorColumnWidth` in `RootView`.
struct StableColumn<Content: View>: View {
    var idealWidth: CGFloat
    // The built view rather than a stored closure, so nothing escaping is kept alive across updates.
    @ViewBuilder var content: Content

    var body: some View {
        Color.clear
            .frame(idealWidth: idealWidth, maxWidth: .infinity, maxHeight: .infinity)
            .overlay { content }
    }
}
