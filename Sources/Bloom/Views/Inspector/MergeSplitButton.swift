import SwiftUI
import BloomCore

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
            // Recreate the menu so its captured selection follows the label.
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
