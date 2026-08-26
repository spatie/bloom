import SwiftUI
import BloomCore

/// Merge, and the chevron that says which merge.
///
/// One control rather than two, which is the whole point of it. The chevron used to be a separate
/// borderless glyph beside the button, and picking a method out of it merged by that method there
/// and then. Now the menu sets the MODE: it ticks the method in force, the button's label changes
/// to match, and the next press on the button is what merges. Nothing in the menu performs
/// anything, so the one irreversible act in this app stays behind the one control that says it.
///
/// **The system's split button, drawn by the system, with the fill painted behind it.** A
/// `Menu` with a `primaryAction` and `.menuStyle(.button)` IS this control on macOS: it draws the
/// hairline, the chevron, the pressed states and the keyboard, and an inline `Picker` inside it
/// draws the tick in the menu's state column, which nothing hand rolled can do. What it does not
/// do is take a colour. Measured on this SDK, rendered offscreen at `controlActiveState.active`:
/// a `Button` with `.borderedProminent` and `.tint(.red)` comes out red, and the same modifiers on
/// a `Menu` come out as the neutral capsule, prominent or not, glass or not. So the state's colour
/// is painted as a rounded rect behind the control and the label is asked for in dark appearance,
/// which is what makes the system draw it, its chevron and its hairline white. That is two lines
/// over a native control, against hand drawing a capsule, a divider, a chevron and a tick.
///
/// The band's colour is a hard requirement rather than decoration: `PullRequestTint.fill` is the
/// rule that the one prominent button carries the colour of the band it stands in, so a red
/// "Checks failing" band ends in a red button. A neutral capsule there would be the strip losing
/// the signal it exists to carry.
struct MergeSplitButton: View {
    /// The method in force for this project. The button promises it, the menu ticks it.
    var method: GitHub.MergeMethod
    /// The colour of the band this stands in. Painted only when this is the prominent control.
    var fill: Color
    /// Whether merging is what this state is asking for, which is what decides between the filled
    /// control and the quiet one beside another state's primary.
    var isPrimary: Bool
    /// Whether GitHub will take a merge at all. A running agent is not in here: the cluster
    /// answers for that, once, for every control in it.
    var canMerge: Bool
    var help: String?
    /// Changes the mode and nothing else.
    var choose: (GitHub.MergeMethod) -> Void
    /// Merges, by the method in force. Opens the confirmation, like every path to a merge here.
    var merge: () -> Void

    /// Whether the CLUSTER is enabled, which is where a running agent's answer arrives. Read
    /// rather than assumed, because the painted fill has to dim with the control it is behind:
    /// a full strength red capsule under a greyed out label reads as a live button.
    @Environment(\.isEnabled) private var isClusterEnabled

    private var isLive: Bool { isClusterEnabled && canMerge }

    @ViewBuilder
    var body: some View {
        if isPrimary {
            // Two forms, as every other control in this strip has, and for the same reason: the
            // headline is the part that must not be what truncates.
            ViewThatFits(in: .horizontal) {
                styled.labelStyle(.titleAndIcon)
                styled.labelStyle(.iconOnly)
            }
            .fixedSize()
        } else {
            // The quiet form is always the glyph, measured rather than chosen: the band is 380
            // points, and "Squash and merge" beside "Commit and push" comes to 326 of them with
            // the number and the gaps still to pay for, which leaves the headline nothing at all.
            // The old chevron was 19 points for the same job; this is 44, and it is what the
            // strip can afford. The method is still said out loud, in the tick in the menu and in
            // the tooltip, which is where an icon only control says everything anyway.
            styled.labelStyle(.iconOnly).fixedSize()
        }
    }

    @ViewBuilder
    private var styled: some View {
        if isPrimary {
            control
                .buttonStyle(.borderedProminent)
                // The label, the chevron and the hairline in white. See the type's note: the
                // system will not tint this control, so the only lever left over its ink is the
                // appearance it draws itself for.
                .environment(\.colorScheme, .dark)
                .background(
                    // Dimmed rather than hidden when the press is not available, which is how
                    // AppKit draws a disabled prominent button and therefore how this one has
                    // to look beside them.
                    fill.opacity(isLive ? 1 : 0.35),
                    in: .rect(cornerRadius: Metrics.corner)
                )
        } else {
            // Quiet, beside somebody else's primary. The strip's rule is that the prominent
            // control is whatever the state is asking for, and when that is Commit and push or
            // Fix merge conflicts, merging is still one press away rather than gone.
            control.buttonStyle(.bordered)
        }
    }

    private var control: some View {
        Menu {
            // An inline `Picker` rather than a `Button` per method, for the reason
            // `ComposerOptionItems` states: the tick lives in an `NSMenu` item's state column,
            // which is the menu's to draw and not a label's, and an inline picker is what asks
            // the platform to draw it. It also cannot perform anything, which is exactly the
            // promise this menu makes.
            Picker("Merge method", selection: binding) {
                ForEach(MergeMethodChoice.offered, id: \.self) { method in
                    // GitHub's own wording here, because this menu is read beside the web UI.
                    // The button says `buttonLabel`, which is a promise about the next press.
                    Text(method.label).tag(method)
                }
            }
            .pickerStyle(.inline)
            // No heading over three items whose tick says what they are, but the picker keeps its
            // name, so the menu still announces itself to VoiceOver.
            .labelsHidden()
        } label: {
            Label(method.buttonLabel, systemImage: "arrow.triangle.merge")
        } primaryAction: {
            merge()
        }
        .menuStyle(.button)
        .controlSize(.regular)
        .disabled(!canMerge)
        // Disabled controls do not explain themselves, and "why is this greyed out" is the whole
        // question a blocked pull request raises.
        .help(help ?? "\(method.buttonLabel), or choose another method from the chevron")
        .fixedSize()
    }

    /// Writing to it changes the mode. There is deliberately no path from here to a merge.
    private var binding: Binding<GitHub.MergeMethod> {
        Binding(get: { method }, set: { choose($0) })
    }
}
