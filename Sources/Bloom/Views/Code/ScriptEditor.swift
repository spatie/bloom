import SwiftUI
import AppKit
import BloomCore

/// A shell script inside a form, shown the way an editor shows one.
///
/// Every script field in Bloom is a buffer of zsh: the setup script, the archive script, each run
/// script, and the read-only mirror of all of them in the preferences window. Before this they
/// were `TextEditor`s and `TextField`s, which is how one of them ended up set flush right against
/// the far edge of the window: a form's value column carries `multilineTextAlignment(.trailing)`
/// in its environment, and plain text obeys it. Code does not survive that, so code is not drawn
/// with a text control here.
///
/// The surface is `SourceEditor`, the same `NSTextView` the file editor in the centre column uses,
/// so there is one syntax theme, one gutter and one set of editing behaviours in the app rather
/// than a second renderer that drifts from the first.
///
/// The height is the other half of the point. A real setup script runs past forty lines; a form
/// row that grows to all of them pushes every section below it off the bottom of the window. So
/// the box takes the height its content wants, between a floor and a ceiling, scrolls beyond
/// that, and can be dragged taller by the grip along its bottom edge when a script needs the room.
struct ScriptEditor: View {
    @Binding var text: String
    var language: Language = .shell
    /// Off for the preferences window's mirror of the resolved settings, which reports rather
    /// than edits.
    var isEditable = true
    var placeholder = ""
    /// Roughly four lines, which is a whole archive script and enough of a setup script to
    /// recognise it.
    var minimumHeight: CGFloat = 92
    /// Roughly eighteen lines. Past this the form is being asked to be an editor.
    var maximumHeight: CGFloat = 340

    @Environment(\.colorScheme) private var colorScheme

    /// Set once the user drags the grip, and from then on it wins: a box somebody sized by hand
    /// must not resize itself out from under the next keystroke.
    @State private var draggedHeight: CGFloat?
    @State private var dragOrigin: CGFloat?

    /// The height a grip is drawn in, and the height it is grabbable over.
    private static let gripHeight: CGFloat = 11

    var body: some View {
        SourceEditor(
            text: $text,
            language: language,
            colorScheme: colorScheme,
            isEditable: isEditable,
            ground: Palette.surfaceSunken,
            placeholder: placeholder
        )
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerSmall))
        .overlay(alignment: .bottom) { grip }
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                .strokeBorder(Palette.border, lineWidth: Metrics.hairline)
        }
        // The editor is a scroll view of its own inside the form's scroll view, and it is the one
        // that should answer here. Without this the row is one tall control as far as the form is
        // concerned and the trailing value column claims it.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var height: CGFloat {
        draggedHeight ?? min(max(naturalHeight, minimumHeight), maximumHeight)
    }

    /// What the script would need if nothing capped it. Counted rather than measured: the editor
    /// does not wrap, so one line of text is one line on screen.
    private var naturalHeight: CGFloat {
        let lines = max(1, text.components(separatedBy: "\n").count)
        return CGFloat(lines) * CodeMetrics.rowHeight + Self.verticalPadding
    }

    /// The text container's inset above and below, plus the grip along the bottom.
    private static let verticalPadding: CGFloat = 12 + gripHeight

    /// A drag handle rather than a resizable window.
    ///
    /// One script is four lines and the next is eighty, and no single height serves both. The grip
    /// is drawn only as a short rule so it reads as an edge to pull rather than as a control, and
    /// it is clamped to the same floor and ceiling the automatic height uses, so dragging cannot
    /// leave a box too small to read or tall enough to swallow the form.
    private var grip: some View {
        ZStack {
            Rectangle()
                .fill(Palette.border)
                .frame(width: 22, height: Metrics.hairline)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.gripHeight)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let origin = dragOrigin ?? height
                    dragOrigin = origin
                    draggedHeight = min(
                        max(origin + value.translation.height, minimumHeight), maximumHeight
                    )
                }
                .onEnded { _ in dragOrigin = nil }
        )
        .accessibilityLabel("Resize the script editor")
    }
}
