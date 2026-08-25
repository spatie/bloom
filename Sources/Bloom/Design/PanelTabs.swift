import SwiftUI

/// Two or three words, one of them chosen, filling the width they are given.
///
/// **A control of our own rather than `Picker(...).pickerStyle(.segmented)`, and the note that
/// asked for one is on `InspectorToolbar.tabPicker`.** It records a measurement: `.tint` cannot
/// reach a SwiftUI segmented picker, because it is an `NSSegmentedControl` whose selected cell is
/// recoloured only through `selectedSegmentBezelColor`, which there is no supported way to set
/// from SwiftUI and which AppKit exposes through no `appearance()` proxy either. That note ends by
/// saying that if a later SDK put the accent back into the selected cell, the answer would be a
/// control of ours rather than a tint. This is that control.
///
/// Two more faults came with the same report, and neither of them is about colour. **A segmented
/// control sizes to its content**: measured in a 444 point slot, the two labels of
/// `WorkspaceSourceTab` laid the control out at 387 points, so a panel that put it in a
/// leading-aligned stack got a strip that stopped short of the right edge, and its two cells were
/// as unequal as its two labels. Cells here are `maxWidth: .infinity` inside an `HStack`, so the
/// strip is exactly as wide as it is offered and every cell is the same fraction of it whatever
/// its label says. **And a segmented control does not truncate**: it overflows and is clipped by
/// whatever is holding it, which is the other half of "not fully visible". A cell here is a `Text`
/// with a line limit, so a strip narrower than its words loses the end of a word rather than the
/// end of a cell.
///
/// **The colours are the ones a selected thing already wears elsewhere in this window**, which is
/// the whole point of not tinting: `Palette.selected`, the quiet fill a resting list row gets, on
/// a `Palette.surfaceSunken` track. Measured against the app's own floors, which
/// `PaletteContrastTests` holds: the selected cell stands off its track at 1.20 to 1 in light and
/// 1.55 in dark, against the 1.2 boundary floor the borders are held to, and the ink on it is
/// `Palette.textPrimary` at 12.5 to 1 and 8.4 to 1. A resting cell keeps `Palette.textTertiary`,
/// which clears the 4.5 text floor on the track at 4.52 and 5.65. It is not allowed onto the
/// selected fill, where it measures 3.76 and 3.64 and would fail, and that is why a chosen cell
/// lifts its ink rather than only changing what is behind it.
///
/// **Three states, and none of them is a colour alone.** A resting cell is tertiary ink on the
/// track, a hovered one is primary ink over `Palette.hover`, and the chosen one is primary ink in
/// medium weight on the fill. The weight is what carries the choice for a reader who cannot
/// separate the two greys, which is the rule `SeverityVocabularyTests` holds everywhere else in
/// this app; equal cells are what let it change without moving anything. Why the hovered cell is
/// not a rung of its own is on `ink(selected:hovered:)`, and it was a picture that settled it.
///
/// Shared rather than local because a second panel wants it, and that panel is here:
/// `QuickPromptMarkPicker` draws Icons and Emojis through this, in a card three hundred points
/// wide inside a popover, where the create sheet's panel is four hundred and sixty in a sheet. It
/// needed no size of its own to get there. Every measurement above is a proportion or a token, the
/// cells divide whatever width they are handed, and the two labels of either caller are short, so
/// the only parameter the second caller added was its own words. The inspector's own tab row is
/// the third of them.
struct PanelTabs<Tab: Hashable>: View {
    /// What the strip as a whole is called, for VoiceOver. The cells carry their own words, so
    /// this is the question they are answers to rather than a repeat of them.
    var label: String
    var tabs: [Tab]
    @Binding var selection: Tab
    var title: (Tab) -> String
    /// Which cell to draw as hovered, whatever the pointer is doing.
    ///
    /// Nil everywhere in the app, and it is not a styling hook. `PanelTabsGallery` photographs this
    /// control offscreen, where there is no pointer to fire an `onHover`, so the one state a
    /// reviewer most needs to compare against the other two is the one a capture cannot reach.
    /// Stated here rather than reimplemented in the gallery, because a second drawing of a hover
    /// is a second answer to what a hover looks like.
    var hovering: Tab?

    init(
        _ label: String,
        tabs: [Tab],
        selection: Binding<Tab>,
        title: @escaping (Tab) -> String,
        hovering: Tab? = nil
    ) {
        self.label = label
        self.tabs = tabs
        self._selection = selection
        self.title = title
        self.hovering = hovering
    }

    /// Which cell the pointer is on, held as the tab and never as an index, for the reason
    /// `WorkspaceSourcePicker.selected` writes out: a list that reorders leaves an index pointing
    /// at whatever has since moved into that slot.
    @State private var pointer: Tab?
    @Namespace private var pill

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.self) { tab in
                cell(tab)
            }
        }
        .padding(Metrics.spacingTight)
        .background {
            RoundedRectangle(cornerRadius: Metrics.corner)
                .fill(Palette.surfaceSunken)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.corner)
                .strokeBorder(Palette.border, lineWidth: Metrics.hairline)
        }
        // Dropped under Reduce Motion rather than slowed, which is what every other call site in
        // this app does with `Motion`: the setting is about movement, not about speed.
        .animation(reduceMotion ? nil : Motion.pane, value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private func cell(_ tab: Tab) -> some View {
        let isSelected = tab == selection
        let isHovered = (hovering ?? pointer) == tab && !isSelected
        return Button {
            selection = tab
        } label: {
            Text(title(tab))
                .font(isSelected ? Typo.labelEmphasis : Typo.label)
                .foregroundStyle(ink(selected: isSelected, hovered: isHovered))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Metrics.spacingSmall)
                .padding(.horizontal, Metrics.spacingSmall)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                            .fill(Palette.selected)
                            // The fill is one view that moves rather than one per cell fading in
                            // and out, so the choice reads as having travelled to where it now is.
                            .matchedGeometryEffect(id: "tabstrip.pill", in: pill)
                    } else if isHovered {
                        RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                            .fill(Palette.hover)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(reduceMotion ? nil : Motion.hover) {
                // Cleared only by the cell that claimed it. Two cells can report in either order
                // as the pointer crosses the boundary between them, and an unconditional clear
                // lets the one being left wipe the one being entered.
                pointer = inside ? tab : (pointer == tab ? nil : pointer)
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Resting ink, or lit ink. Two values rather than three, and the third was tried first.
    ///
    /// A hovered cell was `Palette.textSecondary`, on the reasoning that three states want three
    /// rungs. Photographed, the hovered cell came out DIMMER than the resting one beside it, which
    /// is the opposite of what a hover means. The scale is not the ladder it looks like:
    /// `textSecondary` is `secondaryLabelColor`, half ink, which composites to `#808080` on white
    /// and measures 3.95 to 1, while `Palette.textTertiary` is Bloom's own retuned rung at 4.52.
    /// The system's second rung is below Bloom's third, and its own doc comment says as much.
    ///
    /// So a cell is either resting or lit, and the wash and the weight are what tell hovered from
    /// chosen. Both are what the fill is for anyway; `Palette.hover` is four percent ink, which
    /// carries almost nothing on its own.
    private func ink(selected: Bool, hovered: Bool) -> Color {
        selected || hovered ? Palette.textPrimary : Palette.textTertiary
    }
}
