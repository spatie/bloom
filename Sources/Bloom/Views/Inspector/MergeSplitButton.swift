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
/// **It is the merge button and nothing else.** It is drawn only where the strip's primary action
/// is a merge. An earlier version also stood, quiet and icon only, where the primary was Commit
/// and push or Fix merge conflicts, on the argument that the old chevron was the only way to merge
/// in those states. The owner has overruled that: a menu about merging beside a button about
/// committing is a control the band did not ask for. `PullRequestSummary.mergeControl` carries
/// what that costs.
///
/// **The system's split button, drawn by the system.** A `Menu` with a `primaryAction` and
/// `.menuStyle(.button)` IS this control on macOS: it draws the hairline, the chevron, the pressed
/// states and the keyboard, and an inline `Picker` inside it draws the tick in the menu's state
/// column, which nothing hand rolled can do.
struct MergeSplitButton: View {
    /// The method in force for this project. The button promises it and the menu ticks it, and
    /// they are the same value: see `body` for what it takes to keep that true.
    var method: GitHub.MergeMethod
    /// Whether GitHub will take a merge at all. A running agent is not in here: the cluster
    /// answers for that, once, for every control in it.
    var canMerge: Bool
    var help: String?
    /// Changes the mode and nothing else.
    var choose: (GitHub.MergeMethod) -> Void
    /// Merges, by the method in force. Opens the confirmation, like every path to a merge here.
    var merge: () -> Void

    var body: some View {
        control
            .labelStyle(.titleAndIcon)
            .fixedSize()
            // **The label and the tick are one value, and this is what makes that true.** A
            // `Menu`'s content is not evaluated when the view is rebuilt; it is evaluated when the
            // menu opens, out of the closure SwiftUI stored, and the tick is drawn from the
            // selection that closure captured. The label is re-read on every rebuild. So the
            // button said "Rebase and merge" over a menu still ticking Squash: two ages of one
            // value, which is the exact fault this control exists to remove. Giving it the value's
            // identity makes a changed method a new control, so there is no older closure left to
            // evaluate.
            .id(method)
    }

    private var control: some View {
        Menu {
            // An inline `Picker` rather than a `Button` per method, for the reason
            // `ComposerOptionMenu` states: the tick lives in an `NSMenu` item's state column,
            // which is the menu's to draw and not a label's, and an inline picker is what asks
            // the platform to draw it. It also cannot perform anything, which is exactly the
            // promise this menu makes.
            Picker("Merge method", selection: binding) {
                ForEach(MergeMethodChoice.offered, id: \.self) { offered in
                    // GitHub's own wording here, because this menu is read beside the web UI.
                    // The button says `buttonLabel`, which is a promise about the next press.
                    Text(offered.label).tag(offered)
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
        // Inside both candidates, which is where a `ViewThatFits` needs it: it is what stops the
        // label truncating to fit instead of the row dropping to the shorter form. See `body`.
        .fixedSize()
    }

    /// Writing to it changes the mode. There is deliberately no path from here to a merge.
    private var binding: Binding<GitHub.MergeMethod> {
        Binding(get: { method }, set: { choose($0) })
    }
}
