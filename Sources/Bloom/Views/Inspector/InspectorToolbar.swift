import SwiftUI
import BloomCore

/// The inspector's own tab row: which pane, and the two chrome level choices that outlive
/// whichever file happens to be selected.
///
/// A real segmented control rather than three hand drawn buttons. It is the AppKit control for
/// exactly this choice, so it gets the right metrics, the right selection colour and the right
/// behaviour when the window goes inactive, for free.
///
/// It is only the right control while all three segments fit. Dragged down to the pane's minimum
/// width there is no room for them, and a segmented control does not truncate: it overflows and is
/// clipped by the split view, which is how the tab row ended up cut off at both ends. `ViewThatFits`
/// falls back to a pop-up button, which is what AppKit uses for the same choice in a narrow place.
///
/// Only the controls that mean something for the pane below are drawn. A row of four trailing
/// buttons pushed the picker into its narrow form at the DEFAULT inspector width, and two of them
/// did nothing at all on the checks tab.
struct InspectorToolbar: View {
    @Bindable var model: WorkspaceModel

    /// Shared with `ChangedFileList` through the same defaults key, and outliving the launch
    /// because a user who thinks in folders thinks in folders tomorrow too.
    @AppStorage(ChangedFilePresentation.storageKey)
    private var isTree = ChangedFilePresentation.defaultsToTree

    var body: some View {
        // No spacing of its own: there are exactly two things in the row and the gap between them
        // is the spacer's own minimum. Spelled as a gap on both sides of a spacer it was paid
        // three times, and those points are the difference between a segmented control and a
        // pop-up button at the pane's default width.
        HStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                tabPicker.pickerStyle(.segmented)
                tabPicker.pickerStyle(.menu).fixedSize()
            }
            .labelsHidden()
            .controlSize(.small)

            Spacer(minLength: InspectorLayout.gap)

            trailing
        }
        // The same inset as the pull request strip above it, so the two stacked bars start their
        // contents on one line rather than a few points apart. `FileHeaderBar` uses it too, but it
        // draws in the centre column now rather than under this one.
        .padding(.horizontal, InspectorLayout.inset)
        .frame(height: InspectorLayout.barHeight)
    }

    /// One cluster, spaced the way a toolbar spaces related buttons rather than the way a row
    /// spaces unrelated ones. The points that saves are what let the segmented control survive at
    /// the pane's default width instead of dropping to its pop-up form.
    private var trailing: some View {
        HStack(spacing: Metrics.spacingTight) {
            if model.inspectorTab == .changes {
                // No Review toggle. It existed to hide this list so that the diff under it had
                // room, and the diff is not under it any more: it is a tab in the centre column
                // at the full height of the window, and the list stays beside it the whole time.
                // Walking the files one at a time is Cmd+Option+J and K.
                Toggle(isOn: $isTree) {
                    Label("Group changes by folder", systemImage: "folder")
                }
                .labelStyle(.iconOnly)
                .toggleStyle(.button)
                .inspectorBarControl()
                .disabled(model.changedFiles.isEmpty)
                .help(
                    isTree
                        ? "Show the changed files as a flat list"
                        : "Group the changed files by folder"
                )
            }

            // No Refresh. The list keeps itself current: `AppModel`'s poll re-reads the selected
            // workspace's changed files while the app is frontmost, and a finished turn re-reads
            // them at once. A button asking the reader to do the app's job was only ever covering
            // for that not being true.
            //
            // The items themselves are `WorktreeMenuItems`, which is a view of its own so that
            // this menu can be photographed. See its head.
            Menu {
                WorktreeMenuItems(workspace: model.workspace, pullRequest: model.pullRequest)
            } label: {
                Label("More for this worktree", systemImage: "ellipsis.circle")
            }
            .labelStyle(.iconOnly)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .controlSize(.small)
            .fixedSize()
            .help("More for this worktree")
        }
    }

    /// Untinted, and that is not an oversight.
    ///
    /// This carried `.tint(Palette.selected)` for a while, against a comment saying a segmented
    /// control left alone fills its selected segment with the system accent. Neither half of that
    /// is true on this SDK, and both were measured to settle it. Three pickers were drawn side by
    /// side in one window, one tinted `Palette.selected`, one untinted and one tinted
    /// `Palette.positive`, and the selected segment came out of all three at exactly `#CFCFCF` in
    /// light and `#4B4E54` in dark. `.tint` does not reach the control: SwiftUI's segmented picker
    /// is an `NSSegmentedControl`, and the only thing that recolours its selected cell is
    /// `selectedSegmentBezelColor` on the instance, which there is no supported way to reach from
    /// here. AppKit has no `appearance()` proxy to set it globally either.
    ///
    /// So the tint was a line of code that did nothing, sitting under a comment claiming a colour
    /// decision that was never being made. What it wanted is what the system now does anyway: this
    /// SDK draws the selected segment as a neutral capsule rather than in the accent colour, so
    /// the tab row is already the quiet grey the pull request band above it needs it to be, and
    /// there is nothing left for a tint to fix. If a future SDK puts the accent back in it, this is
    /// the note to come back to, and the answer will be a control of our own rather than a tint.
    private var tabPicker: some View {
        Picker("Inspector view", selection: $model.inspectorTab) {
            ForEach(InspectorTab.allCases, id: \.self) { tab in
                Text(title(for: tab)).tag(tab)
            }
        }
    }

    private func title(for tab: InspectorTab) -> String {
        guard tab == .changes, !model.changedFiles.isEmpty else { return tab.rawValue }
        return "\(tab.rawValue) (\(model.changedFiles.count))"
    }

}
