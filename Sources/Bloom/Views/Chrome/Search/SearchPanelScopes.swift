import SwiftUI
import BloomCore

/// The chips at the head of the panel's list: Everything, Workspaces, Transcripts, Archived, each
/// with its count in a round.
///
/// # It was Home's segmented picker, and it is not any more
///
/// The panel borrowed `HomeBar`'s control outright: one `Picker` in `.segmented` over the same
/// `HomeScope.offered(searching:)`, with the count interpolated into each segment's title. That
/// was deliberate in the specification and it was the wrong call for this surface. The owner's
/// report was that the chips "do not feel native", and the two things underneath that judgement
/// are both real.
///
/// A segmented control is a form control. It is right at the head of a pane, attached to the
/// title bar, which is where Finder puts a scope bar and where Home's strip is; it is wrong inside
/// a floating card over glass, where macOS 26's own Spotlight draws a row of capsules and not a
/// segmented switch. And a segment's label is a `Text`, so a count in it can only ever be more
/// words in the same string: there is nowhere to put a round.
///
/// **So the two surfaces differ now, and Home is deliberately untouched.** Its picker is in a
/// toolbar strip, which is exactly where a segmented control belongs, and this is a floating
/// panel. The chips still come off `HomeScope.offered(searching:)` and the numbers still come off
/// `HomeScopeCounts`, so the two cannot offer different scopes or different answers for one
/// machine; what differs is the chrome, and it differs because the two places are different.
///
/// # Nothing here moves while somebody types
///
/// Every chip is a label and a badge, the labels are constants, and `CountBadge` reserves three
/// digits whatever it holds. So the row is the same shape at "Everything 13, Workspaces 12,
/// Transcripts 1, Archived 10" as it is at "Everything 1, Workspaces 1, Transcripts 0,
/// Archived 1", which was the exact jump the owner reported. A scope with nothing in it draws a
/// nought rather than dropping its badge, and `CountBadge` says why.
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
            HStack(spacing: Metrics.spacingSmall) {
                Text(label)
                    .font(Typo.caption)
                    .lineLimit(1)
                    .fixedSize()

                CountBadge(count: count, isOnSelection: isEmphasized)
            }
            .foregroundStyle(isEmphasized ? Palette.selectedEmphasizedText : Palette.textSecondary)
            // Inside the label, which is the whole of the bug `WindowPaneToggle` records: a
            // `.plain` Button takes its clicks inside its label, so padding put outside the
            // finished Button is padding nothing can be pressed on.
            .padding(.horizontal, Metrics.spacingWide)
            .padding(.vertical, Metrics.chipInsetV)
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
