import SwiftUI
import BloomCore

/// A control's explanation, shown by the bar it sits in the moment the pointer lands on it.
///
/// **This exists because `.help` is not ours to make faster.** A SwiftUI `.help` is an AppKit
/// tooltip, and when a tooltip appears is a system setting: `NSToolTipManager`'s initial delay,
/// which belongs to the person using the Mac and applies to every application on it. It measures
/// about a second and a half out of the box, which is what a reviewer reading a Bloom diff for the
/// first time reported as the row of glyphs above it being unreadable. Writing to that setting to
/// make one bar feel quicker would be reaching outside this app to change something the user set
/// for all of them, so it is left alone. See `FileBarControls` for the other half of the answer,
/// which is that the controls carry their words wherever there is room for them.
///
/// What is drawn instead is not a tooltip at all: it is a line of text in the bar's own row,
/// swapped in on `onHover` and therefore instant. Nothing is layered over the file below, nothing
/// takes a click, and the whole thing disappears the moment the pointer leaves.
///
/// The `.help` is kept on every control alongside it, and deliberately. It is what VoiceOver reads
/// as the accessibility hint, it is what a keyboard user gets with no pointer to hover with, and
/// it is what the bar shows to somebody whose pointer is over a control in a WINDOW that is not
/// frontmost, where `onHover` does not fire.
extension View {
    /// Reports this control's sentence while the pointer is over it, and keeps it as the tooltip.
    ///
    /// - Parameter hint: the bar's own state, which is what draws the sentence.
    func fileBarHint(_ control: FileBarControl, into hint: Binding<String?>) -> some View {
        // **Cleared only if it is still ours.** Moving between two controls that touch sends the
        // second one's enter before the first one's exit, so a bare `hint = nil` on exit blanks
        // the sentence that has just been set and the row flickers empty as the pointer crosses
        // the gap. Comparing first means the last control entered wins, which is the one the
        // pointer is actually over.
        onHover { isInside in
            if isInside {
                hint.wrappedValue = control.hint
            } else if hint.wrappedValue == control.hint {
                hint.wrappedValue = nil
            }
        }
        .help(control.hint)
    }
}

/// The sentence itself, drawn at the trailing end of the bar beside the control it belongs to.
///
/// One line, ever. It sits in the slack between the file's path and the controls, and the bar
/// gives it the lowest layout priority in the row, so a bar too narrow to hold both keeps the path
/// and the controls where they were and truncates the sentence instead. A hint that pushed the
/// controls along as it appeared would move the target out from under a pointer already on it.
///
/// Drawn with an empty string rather than taken out of the row when there is nothing to say, so
/// the number of children in the bar's stack, and therefore the number of gaps between them, is
/// the same whether anything is being pointed at or not.
struct FileBarHintLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Typo.caption)
            .foregroundStyle(Palette.textSecondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .accessibilityHidden(true)
    }
}
