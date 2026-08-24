import SwiftUI

/// A row that owns its own hover, wrapped around a row that cannot.
///
/// Hover used to be one `@State` on the list: `hoveredPath` in `ChangedFileList` and `hovered` in
/// `FileTreeView`. Crossing a single row boundary is two writes to it, the leave and the enter,
/// and every write re-ran the whole list's body and rebuilt every row the lazy stack had realised.
/// Dragging the pointer down a list of forty changed files is eighty full list passes.
///
/// The obvious fix is a `@State` inside the row, and it does not work here. Those rows read
/// `\.isOnEmphasizedSelection` out of their PARENT's environment to invert the marks that carry
/// meaning (see `ChangedFileRow`), and `RowBackground` puts that value into the environment of the
/// content it is applied to, so a row that applied `.rowBackground` to itself would be the one
/// view in the window that could not see it. The state moves one level up instead, into this
/// wrapper, which paints the fill and tracks the pointer with the row inside it.
///
/// Selection stays on the list, where it belongs: one row at a time is selected and the list is
/// what knows which. Only hover comes down here, because hover is the one that moves per frame.
struct HoverRow<Content: View>: View {
    var isSelected: Bool
    /// Whether the list this row belongs to has keyboard focus. See `RowBackground`.
    var isFocused: Bool = false
    /// Held as a value rather than as a closure, so a redraw caused by the pointer arriving
    /// re-applies the fill to the row it already has instead of building a new one. A row that is
    /// `Equatable` then costs nothing at all on a hover.
    var content: Content

    @State private var isHovered = false

    init(isSelected: Bool, isFocused: Bool = false, @ViewBuilder content: () -> Content) {
        self.isSelected = isSelected
        self.isFocused = isFocused
        self.content = content()
    }

    var body: some View {
        content
            .rowBackground(isSelected: isSelected, isHovered: isHovered, isFocused: isFocused)
            .onHover { isHovered = $0 }
    }
}
