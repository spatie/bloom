import SwiftUI
import BloomCore

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
    enum Numbers {
        case both
        case old
        case new
    }

    var line: DiffLine?
    var numbers: Numbers

    var body: some View {
        HStack(spacing: 0) {
            switch numbers {
            case .both:
                number(line?.oldNumber)
                number(line?.newNumber)
            case .old:
                number(line?.oldNumber)
            case .new:
                number(line?.newNumber)
            }
        }
        // No tint of its own. A grey column against the white the code sits on put a hard vertical
        // edge down the left of every diff, and a hard edge is read as a boundary between two
        // things rather than as the margin of one. The row's wash runs under this and under the
        // code alike, which leaves the numbers to be told apart by being dimmed and monospaced,
        // and that is what separates a ruler from content anyway.
    }

    /// Right aligned, dimmed and monospaced, so a column of numbers reads as a ruler rather than
    /// as content competing with the code beside it.
    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .font(Typo.codeTiny)
            .monospacedDigit()
            .foregroundStyle(Palette.textTertiary)
            .frame(width: CodeMetrics.numberWidth, alignment: .trailing)
            .padding(.trailing, CodeMetrics.gutterPadding)
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
    static func speech(for line: DiffLine?) -> String {
        guard let line else { return "" }
        if line.kind == .noNewline { return "No newline at end of file" }

        let number = line.newNumber ?? line.oldNumber
        let place = number.map { " \($0)" } ?? ""
        let state = switch line.kind {
        case .addition: "Added line\(place)"
        case .deletion: "Removed line\(place)"
        default: "Line\(place)"
        }

        let text = line.text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "\(state), empty" : "\(state), \(text)"
    }
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

    var body: some View {
        Text(text)
            .font(Typo.codeTiny)
            .foregroundStyle(Palette.textTertiary)
            .frame(width: CodeMetrics.markerWidth, alignment: .center)
    }

    private var text: String {
        switch line?.kind {
        case .addition: "+"
        case .deletion: "-"
        case .noNewline: "\\"
        default: " "
        }
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
    var spot: ReviewSpot
    var isRowHovered: Bool
    var onComment: (ReviewSpot) -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        let shown = isRowHovered || isFocused
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
        .padding(.leading, Metrics.spacingTight)
        .help("Comment on this line")
        .accessibilityLabel("Comment on line \(spot.line)")
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
