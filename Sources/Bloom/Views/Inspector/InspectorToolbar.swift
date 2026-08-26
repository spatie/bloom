import SwiftUI
import BloomCore

/// The inspector's own tab row: which pane, and the two chrome level choices that outlive
/// whichever file happens to be selected.
///
/// A real segmented control rather than three hand drawn buttons. It is the AppKit control for
/// exactly this choice, so it gets the right metrics, the right selection colour and the right
/// behaviour when the window goes inactive, for free.
///
/// It is only the right control while every segment fits. Dragged down to the pane's minimum
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

                // What the list is measured from. On this tab only, because it is the only pane
                // the scope means anything for: the file tree is the whole worktree and the checks
                // list is GitHub's. Which scope is in force is said by the band under this row
                // rather than in it, for the width reason `DiffScopeBand` spells out.
                Menu {
                    DiffScopeMenuItems(model: model)
                } label: {
                    Label(
                        "What the changes are measured from",
                        systemImage: "line.3.horizontal.decrease.circle"
                    )
                }
                .labelStyle(.iconOnly)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .controlSize(.small)
                .fixedSize()
                .help("What the changes are measured from")
                // One glyph, in one colour, whichever scope is in force. It carried
                // `.foregroundStyle(Palette.accent)` while narrowed for a while; photographed in
                // both states the two glyphs came out at exactly the same grey, because a
                // borderless `Menu` is an `NSPopUpButton` and a foreground style set out here does
                // not reach the image it draws. `.symbolVariant(.fill)` does reach it, and a
                // filled disc in a row of outlines is louder than this control has any business
                // being. The band under this row is what says the list is narrowed, and it says it
                // in a sentence rather than by a shade of a glyph nobody would notice.
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
    /// decision that was never being made. That half is settled: `.tint` cannot reach this control
    /// whatever it draws.
    ///
    /// **The colours above were measured in a window that was not key, and that is not the same
    /// question.** They came off `--gallery system-accent`, which is captured with `needsFocus`
    /// false, and every accented control on this platform drops to a neutral grey while its window
    /// is inactive: that page says so itself about the switch beside it. `#CFCFCF` and `#4B4E54`
    /// are those greys. In a key window `NSAccentColorName` in `Resources/Info.plist` makes this
    /// process's `controlAccentColor` Bloom's own `accentFill`, and the owner's screenshot of a
    /// live window shows the selected segment carrying it. Which is the right outcome and needs
    /// nothing done to it: the accent it fills with is ours.
    ///
    /// Do not add glass here. `.glassEffect` shapes a view's own background, and this is one
    /// `NSSegmentedControl` rather than three views, so a tinted glass segment means drawing the
    /// strip by hand and freezing it at today's look. Measured for the record: white on
    /// `.regular.tint(accentFill)` over this pane's light ground is 4.32 to 1 at a tint as strong
    /// as nine tenths and 2.99 at seven tenths, against a floor of 4.5. Bloom's light surface is
    /// pure white, so any translucency drags the fill towards the ink on it. Flat `accentFill` is
    /// 5.24.
    private var tabPicker: some View {
        // Whichever tabs this workspace has, rather than all three. Checks is only offered when
        // GitHub has reported a run for the branch, so a workspace with no pull request draws two
        // segments and no gap where a third used to be. `InspectorTab.available` is where that is
        // decided and why it is decided there.
        Picker("Inspector view", selection: $model.inspectorTab) {
            ForEach(model.availableInspectorTabs, id: \.self) { tab in
                Text(title(for: tab)).tag(tab)
            }
        }
    }

    /// **The number is the diff's, and it does not follow the filter field under this row.**
    ///
    /// This is the tab's name rather than the list's heading, and a name that changed as somebody
    /// typed would move the segment out from under a click already on its way to it, which is the
    /// same reason `InspectorTab.available` puts the conditional tab last. It also answers a
    /// different question: how much the agent changed is worth knowing while you are hunting for
    /// one file inside it, and the field holding a word is what says the list below is showing
    /// fewer.
    private func title(for tab: InspectorTab) -> String {
        guard tab == .changes, !model.changedFiles.isEmpty else { return tab.rawValue }
        return "\(tab.rawValue) (\(model.changedFiles.count))"
    }

}
