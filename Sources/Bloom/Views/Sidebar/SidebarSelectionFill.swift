import SwiftUI
import AppKit
import BloomCore

/// What a selected row in the sidebar is painted with: one quiet grey, in every state.
///
/// **Drawn here rather than left to the list, and that is the fix for a report.** `#254` handed
/// the selection back to the `NSOutlineView` under the `List`. AppKit fills a selected row with the
/// accent colour whenever the table is first responder in the key window, and Bloom's accent is
/// its house blue, so switching away from Bloom and back with the pane holding the keyboard turned
/// the selected workspace solid `#197593` under ink that stayed dark. The owner had already asked
/// for the grey, after comparing the pane with Finder's sidebar, and asked for it again. The rule
/// is `SidebarSelectionStyle`, in the core.
///
/// A `listRowBackground` replaces the table's own selection drawing in this list rather than
/// sitting on top of it, which is what let `69dc61d3` paint the pane blue while it was resting and
/// `874c2050` paint it grey while it was focused. Home's rows need an opaque ground to hide the
/// accent (see `HomeRowBackground`), but that is an inset list, and the sidebar is glass.
///
/// The keyboard is shown with an edge, not a colour. The fill is identical in both selected
/// states, so nothing about the report can come back, and the edge is what says the arrow keys are
/// pointed at this pane.
struct SidebarSelectionFill: View {
    var style: SidebarSelectionStyle

    /// Ink at an alpha rather than an opaque step, because the pane is glass over the window's blue
    /// wash: `Palette.selected` composited to within a few units of what was under it and the
    /// selected workspace had a fill nobody could see. Measured in `114a389d`, where nine percent
    /// black, Finder's figure, read as a heavy slab over the glass, so it is six, and nine in dark.
    static let fill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.09)
            : NSColor(white: 0, alpha: 0.06)
    })

    /// How far the fill is held off each edge of the pane. A `listRowBackground` is handed the whole
    /// row rect, and ten points is where AppKit drew its own band, measured off a capture in
    /// `69dc61d3`, so taking the drawing back changes the colour and not the layout.
    static let inset: CGFloat = 10

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
        shape
            .fill(Self.fill)
            .overlay {
                if style.drawsKeyboardEdge {
                    shape.strokeBorder(Palette.textTertiaryOnGlass, lineWidth: Metrics.hairline)
                }
            }
            .padding(.horizontal, Self.inset)
    }
}

extension View {
    /// Puts Bloom's selection under a selectable sidebar row, and keeps the row's ink ordinary.
    ///
    /// Nothing rather than `Color.clear` for a row that is not selected: a clear row background
    /// still replaces the list's own drawing, so the row would lose its hover wash.
    ///
    /// `backgroundProminence` is pinned to standard because the rows read it to invert their marks
    /// and counts to white (see `WorkspaceRow.isEmphasized`). Those inversions belong to an accent
    /// fill, and on this grey white ink is the unreadable case `62318846` removed from the quick
    /// prompts.
    func sidebarSelection(_ style: SidebarSelectionStyle) -> some View {
        listRowBackground(Group {
            if style.drawsFill {
                SidebarSelectionFill(style: style)
            }
        })
        .environment(\.backgroundProminence, .standard)
    }
}
