import SwiftUI
import AppKit
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
    @Binding var isReviewing: Bool

    /// Shared with `ChangedFileList` through the same defaults key, and outliving the launch
    /// because a user who thinks in folders thinks in folders tomorrow too.
    @AppStorage(ChangedFilePresentation.storageKey)
    private var isTree = ChangedFilePresentation.defaultsToTree

    /// Non-nil for as long as it takes the sharing menu to open. See `SharePicker`.
    @State private var sharing: SharePayload?

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
        // The same inset as the pull request strip above and the file header bar below, so the
        // three stacked bars start their contents on one line rather than a few points apart.
        .padding(.horizontal, InspectorLayout.inset)
        .frame(height: InspectorLayout.barHeight)
    }

    /// One cluster, spaced the way a toolbar spaces related buttons rather than the way a row
    /// spaces unrelated ones. The points that saves are what let the segmented control survive at
    /// the pane's default width instead of dropping to its pop-up form.
    private var trailing: some View {
        HStack(spacing: Metrics.spacingTight) {
            if model.inspectorTab == .changes {
                Toggle(isOn: $isReviewing) {
                    Label("Review changes", systemImage: "eye")
                }
                .labelStyle(.iconOnly)
                .toggleStyle(.button)
                .inspectorBarControl()
                .disabled(model.changedFiles.isEmpty)
                .help("Review the changes one file at a time")
                .onChange(of: isReviewing) { _, reviewing in
                    guard reviewing, model.selectedFilePath == nil else { return }
                    model.selectedFilePath = model.changedFiles.first?.path
                }

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
            Menu {
                Button("Copy branch name", action: copyBranch)
                Button("Reveal worktree in Finder") { Reveal.inFinder(model.workspace.path) }
                Button("Open worktree in Editor") { Reveal.inEditor(model.workspace.path) }
                if let pullRequest = model.pullRequest {
                    Divider()
                    Button("Open pull request") { GitHubBridge.open(pullRequest.url) }
                    if let url = URL(string: pullRequest.url) {
                        // Here rather than in the pull request strip above. That strip already
                        // clips at the pane's narrow widths, and one more control in it buys
                        // discoverability with the merge button's room.
                        Button("Share pull request") { sharing = .link(url) }
                    }
                }
            } label: {
                Label("More for this worktree", systemImage: "ellipsis.circle")
            }
            .labelStyle(.iconOnly)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .controlSize(.small)
            .fixedSize()
            .help("More for this worktree")
            // The anchor sits on the menu itself, so the sharing menu drops out of the button the
            // reader just used rather than out of the corner of the window.
            .sharePicker(payload: $sharing)
        }
    }

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

    // MARK: - Actions

    private func copyBranch() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.workspace.branch, forType: .string)
    }
}
