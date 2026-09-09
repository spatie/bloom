import SwiftUI
import BloomCore
import BloomUI

/// The line number columns of a diff row.
///
/// **Shared rather than written twice, because a diff draws two kinds of row at once.** Most rows
/// are now a `DiffRunView`, several lines of code in one selectable text object with a column of
/// these beside it; the rows a run may not swallow (see `DiffRunGrouping`) are still a
/// `DiffLineView` each. Both appear in the same file, interleaved, so the two gutters have to be
/// the same gutter to the point: a column that disagreed by half a point would step in and out
/// down the left of every diff at exactly the places a comment band sits.
struct DiffGutter: View {
    /// Which gutters a row shows. Side by side shows one, unified shows both.
    ///
    /// Here rather than on `DiffLineView`, which is where it used to live, because the run view
    /// needs it too and neither of them owns the other. `DiffLineView.Numbers` still resolves, so
    /// the diff's own signatures did not have to move with it.
    typealias Numbers = BloomDiffGutter.Numbers

    var line: DiffLine?
    var numbers: Numbers
    @Environment(\.fontScale) private var fontScale

    var body: some View {
        BloomDiffGutter(line: line, numbers: numbers, font: Typo.codeTiny.resolved(scale: fontScale),
                        foreground: Palette.textTertiary,
                        numberWidth: CodeMetrics.numberWidth, padding: CodeMetrics.gutterPadding)
    }

    /// How wide this column comes out, which the run view needs as a number because it paints the
    /// row washes as a layer behind the columns rather than as each row's own background.
    static func width(for numbers: Numbers) -> CGFloat {
        let cell = CodeMetrics.numberWidth + CodeMetrics.gutterPadding
        return numbers == .both ? cell * 2 : cell
    }

    /// What this line is, where it is, and what it says, in that order.
    ///
    /// One element per line, said as a sentence. Left as it was drawn, VoiceOver read a row as
    /// four unrelated fragments, "128", "129", "+", and then the code, and whether a line was
    /// added or removed reached the reader only as a background wash and a one-character marker
    /// that is a bare space on a context line. A colour is not a label.
    static func speech(for line: DiffLine?) -> String { BloomDiffGutter.speech(for: line) }

}

/// The one character column that says whether a line was added, removed or left alone.
///
/// Beside the code rather than inside the gutter, and that is load bearing for the split layout:
/// a row with nothing opposite it paints `Palette.surfaceSunken` from HERE to the end of the sheet,
/// so a marker moved in with the numbers would leave a stripe of pane colour inside the sunken
/// band. See `DiffRunView.wash` and `DiffLineView.content`, which both start the fill at this
/// column's leading edge.
struct DiffMarker: View {
    var line: DiffLine?
    @Environment(\.fontScale) private var fontScale

    var body: some View {
        BloomDiffMarker(line: line, font: Typo.codeTiny.resolved(scale: fontScale),
                        foreground: Palette.textTertiary, width: CodeMetrics.markerWidth)
    }

}

/// The `+` in the gutter, sitting over the line number the way Conductor draws it.
///
/// Always in the hierarchy and hidden by drawing in clear rather than built on hover or faded with
/// `.opacity`, so it is reachable by Tab under Full Keyboard Access and readable by VoiceOver: a
/// control that only exists while a pointer floats over it is a control a keyboard can never
/// reach. Not `.opacity(0)`, on the button or on its label, because either took the element out of
/// the accessibility tree entirely, measured by it vanishing from the AX hierarchy, which silently
/// broke the row's spoken sentence. Clear colours draw the same nothing while the button keeps its
/// hit region and its element, which is also what makes the hover reveal feel instant.
///
/// **Its own `@FocusState`, one per instance, which is what lets a run of lines carry a column of
/// these.** The state used to live on the row, and a run has no row to put it on.
///
/// **It is overlaid by its caller AFTER the accessibility collapse, never inside it.**
/// `children: .ignore` swallows every descendant of whatever it is applied to, so a button inside
/// the collapsed element is a button VoiceOver and the keyboard cannot reach, and the claim in the
/// paragraph above would be quietly false. Both callers overlay it as a sibling of the collapsed
/// row for that reason.
struct DiffCommentButton: View {
    /// How far the pointer has to travel before a press becomes a drag across lines.
    ///
    /// Far enough that a click is never read as a one line drag, since the two do the same thing
    /// and the button's own action is what a click should reach; short enough that a deliberate
    /// pull downwards starts selecting inside the first row. A quarter of a row.
    static let dragThreshold: CGFloat = 4

    var spot: ReviewSpot
    var isRowHovered: Bool
    var onComment: (ReviewSpot) -> Void
    /// How far a drag from this row has travelled, in points, positive downwards. Nil, the
    /// default, leaves this a plain button, which is what a caller that cannot say where a drag
    /// would land passes.
    var onDrag: ((CGFloat) -> Void)?
    /// The pointer let go, so whatever the drag selected is what the comment is about.
    var onDragEnd: (() -> Void)?

    @FocusState private var isFocused: Bool
    /// Drawn while a drag is in progress even though the pointer has left this row, because the
    /// `+` is the handle being dragged and a handle that vanishes mid gesture reads as the drag
    /// having been dropped.
    @State private var isDragging = false

    var body: some View {
        let shown = isRowHovered || isFocused || isDragging
        Button {
            onComment(spot)
        } label: {
            Image(systemName: "plus")
                .font(Typo.micro)
                .fontWeight(.bold)
                .foregroundStyle(shown ? Palette.selectedEmphasizedText : .clear)
                .frame(width: 16, height: 16)
                .background(
                    shown ? Palette.controlAccent : .clear,
                    in: RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        // Simultaneous, so the button keeps its own click. A drag that passes the threshold ends
        // outside the button's bounds, where a `Button` does not fire, and a click that never
        // reaches the threshold never starts this gesture at all: the two paths cannot both run
        // on one press. A drag pulled out and brought back is the one case where they can, and it
        // costs nothing, because both of them open the editor on the same single line.
        .modifier(DiffCommentDrag(onDrag: onDrag, onDragEnd: onDragEnd, isDragging: $isDragging))
        .padding(.leading, Metrics.spacingTight)
        .help(onDrag == nil ? "Comment on this line" : "Comment on this line, or drag over several")
        .accessibilityLabel("Comment on line \(spot.line)")
    }
}

/// The drag that turns the gutter `+` into a range selector, attached only where the row can say
/// which line the pointer has reached.
///
/// A modifier rather than an `if` inside the button's body, because a view that is sometimes
/// wrapped in a gesture and sometimes not is two different view types to SwiftUI, and the
/// identity change resets the `@FocusState` and the hover of every `+` in the diff the first time
/// a caller stops passing the closures.
private struct DiffCommentDrag: ViewModifier {
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?
    @Binding var isDragging: Bool

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: DiffCommentButton.dragThreshold)
                .onChanged { value in
                    guard let onDrag else { return }
                    isDragging = true
                    onDrag(value.translation.height)
                }
                .onEnded { _ in
                    guard onDrag != nil else { return }
                    isDragging = false
                    onDragEnd?()
                }
        )
    }
}

/// Which line a row offers to edit in place, filtered to the side it is drawing.
///
/// Only the new side, and the rule is `DiffLine.reviewSpot`'s rather than a second reading of the
/// same line: an addition and a context line are the file as it is now, and a deletion is text
/// that is not in the file at all, so there is nothing there to type into. Reusing that property
/// is also what keeps the `+` and this menu item agreeing about which pane a line belongs to in
/// the split layout, which is the disagreement `DiffCommentSpot` exists to prevent.
///
/// What the line then opens, which is the block of added lines around it or the context line
/// alone, is `DiffEdit.region` in the core, where it is tested against a file on disk.
enum DiffEditTarget {
    static func offered(
        for line: DiffLine?,
        numbers: DiffGutter.Numbers,
        enabled: Bool
    ) -> Int? {
        guard enabled, numbers != .old, let spot = line?.reviewSpot, spot.side == .new else {
            return nil
        }
        return spot.line
    }
}

/// Which spot a row offers to hang a comment on, filtered to the side it is drawing.
///
/// In side by side a context line appears in both panes; only the new-side pane offers it, so one
/// line never grows two buttons meaning the same thing. Shared by the per line rows and the run
/// rows, and `DiffView.spots(of:numbers:)` makes the same split when it decides where a band
/// lands, so a `+` and the band it produces can never disagree about which pane they belong to.
enum DiffCommentSpot {
    static func offered(
        for line: DiffLine?,
        numbers: DiffGutter.Numbers,
        enabled: Bool
    ) -> ReviewSpot? {
        guard enabled, let spot = line?.reviewSpot else { return nil }
        switch numbers {
        case .both: return spot
        case .old: return spot.side == .old ? spot : nil
        case .new: return spot.side == .new ? spot : nil
        }
    }
}
