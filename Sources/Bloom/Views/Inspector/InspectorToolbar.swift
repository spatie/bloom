import SwiftUI
import BloomCore

/// The inspector's own tab row: which pane, and the two chrome level choices that outlive
/// whichever file happens to be selected.
///
/// Tabs connect the selected scope to the pane below. When the inspector becomes too narrow for
/// the labels, `ViewThatFits` falls back to a pop-up button.
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
    @Namespace private var tabSelection

    var body: some View {
        // No spacing of its own: there are exactly two things in the row and the gap between them
        // is the spacer's own minimum. Spelled as a gap on both sides of a spacer it was paid
        // three times, and those points are the difference between a segmented control and a
        // pop-up button at the pane's default width.
        HStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                tabStrip
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

    /// The compact fallback for a width that cannot hold the tab labels.
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

    private var tabStrip: some View {
        HStack(spacing: 0) {
            ForEach(model.availableInspectorTabs, id: \.self) { tab in
                let isSelected = model.inspectorTab == tab
                Button {
                    model.inspectorTab = tab
                } label: {
                    Text(title(for: tab))
                        .font(Typo.label)
                        .foregroundStyle(
                            isSelected ? Palette.textPrimary : Palette.textSecondary
                        )
                        .lineLimit(1)
                        .padding(.horizontal, InspectorLayout.inset)
                        .frame(height: InspectorLayout.barHeight)
                        .background {
                            if isSelected {
                                UnevenRoundedRectangle(
                                    topLeadingRadius: Metrics.cornerSmall,
                                    topTrailingRadius: Metrics.cornerSmall
                                )
                                .fill(Palette.surface)
                                .overlay {
                                    TabItemOutline(radius: Metrics.cornerSmall)
                                        .strokeBorder(
                                            Palette.border,
                                            lineWidth: Metrics.outline
                                        )
                                }
                                .padding(.bottom, Metrics.outline)
                                .matchedGeometryEffect(
                                    id: "inspector.tab.selection",
                                    in: tabSelection
                                )
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
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
