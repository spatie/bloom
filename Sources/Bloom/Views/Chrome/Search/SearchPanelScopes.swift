import SwiftUI
import BloomCore

/// The chips at the head of the panel's list: Everything, Workspaces, Transcripts, Archived, each
/// with its count.
///
/// # It was Home's segmented picker, then a row of pills, and it is a row of controls now
///
/// The panel borrowed `HomeBar`'s control outright, which was deliberate in the specification and
/// wrong for this surface: a segmented control is right at the head of a pane, attached to the
/// title bar, and wrong inside a floating card. That much still holds and Home still has its
/// picker, which is untouched here and should stay: its strip IS attached to the title bar.
///
/// What replaced it was a row of capsules, each holding a filled round with its count in, and the
/// owner said twice that they do not feel native. He is right, and the fault was the round rather
/// than the capsules. **Two nested capsules is a web pill.** The inner one had nowhere to sit,
/// because the outer one was only as tall as its own text, so the number touched the border of the
/// thing holding it in every state. And a filled round means something specific on this platform:
/// Mail draws one in the sidebar for unread mail, and a notification badge is the same idiom, a
/// thing wanting your attention. "How much would pressing me show" is a different sentence and
/// macOS sets it as a quiet trailing number. See `CountLabel`.
///
/// So: one capsule, not two. The count is a number a step quieter than the label beside it. The
/// chip is `Metrics.controlHeight` tall, which is the height every other small control in this app
/// is drawn at, with `Metrics.gutter` of air either side of its content, so it reads as a control
/// with room in it rather than as a label somebody drew a border around.
///
/// **Only the lit chip carries a fill, and that is the native shape rather than a saving.** Three
/// plain labels and one filled capsule is what a floating panel does with a set of filters; four
/// filled capsules is a web tab bar. The unlit ones take `Palette.hover` under the pointer, which
/// is how every other quiet control in this window says it can be pressed.
///
/// # Nothing here moves while somebody types
///
/// The labels are constants and `CountLabel` reserves three digits whatever it holds, so the row
/// is the same shape at "Everything 131, Workspaces 6, Transcripts 125, Archived 10" as at
/// "Everything 1, Workspaces 1, Transcripts 0, Archived 1", which was the exact jump reported. A
/// scope with nothing in it draws a nought rather than dropping its number, and the counts carry
/// no thousands separator, which is `Figures.count`: both of those were their own reports.
///
/// Tab and Shift+Tab step them, which is why nothing here is ever given the keyboard: the field
/// keeps it, and `SearchPanelKeys` decides what Tab means. See `MenuSearchField`.
struct SearchPanelScopes: View {
    var counts: HomeScopeCounts
    @Binding var scope: HomeScope

    var body: some View {
        HStack(spacing: Metrics.spacingSmall) {
            ForEach(HomeScope.offered(searching: true), id: \.self) { offered in
                ScopeChip(
                    label: offered.label(searching: true),
                    count: counts.count(of: offered, searching: true),
                    isOn: offered == scope
                ) {
                    scope = offered
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.inset)
        .padding(.bottom, Metrics.spacingSmall)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Choose which kind of thing the answer is narrowed to")
    }
}

/// One chip. A view of its own because hover is per chip state and the row above has nowhere to
/// keep four of them.
private struct ScopeChip: View {
    var label: String
    var count: Int
    var isOn: Bool
    var pick: @MainActor () -> Void

    @Environment(\.controlActiveState) private var activeState
    @State private var isHovered = false

    var body: some View {
        Button(action: pick) {
            HStack(spacing: Metrics.spacing) {
                Text(label)
                    .font(Typo.caption)
                    .lineLimit(1)
                    .fixedSize()

                CountLabel(count: count, isOnSelection: isEmphasized)
            }
            .foregroundStyle(isEmphasized ? Palette.selectedEmphasizedText : Palette.textSecondary)
            // Inside the label, which is the whole of the bug `WindowPaneToggle` records: a
            // `.plain` Button takes its clicks inside its label, so padding put outside the
            // finished Button is padding nothing can be pressed on.
            .padding(.horizontal, Metrics.gutter)
            .frame(height: Metrics.controlHeight)
            .background(fill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHoverChange { isHovered = $0 }
        .accessibilityLabel("\(label), \(count)")
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    /// The accent is only honest while the window can act on a key, which is the same rule
    /// `RowBackground` keeps for the rows underneath these.
    private var isEmphasized: Bool {
        isOn && activeState != .inactive
    }

    private var fill: Color {
        if isEmphasized { return Palette.selectedEmphasized }
        if isOn { return Palette.selected }
        return isHovered ? Palette.hover : .clear
    }
}
