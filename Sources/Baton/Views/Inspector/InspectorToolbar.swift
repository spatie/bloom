import SwiftUI
import AppKit
import BatonCore

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
struct InspectorToolbar: View {
    @Bindable var model: WorkspaceModel
    @Binding var isReviewing: Bool

    /// Shared with `DiffView` through the same defaults key, so the toggle and the diff can never
    /// disagree about which layout is showing.
    @AppStorage(DiffLayoutSetting.storageKey) private var isSideBySide = false
    /// Shared with `ChangedFileList` the same way, and outliving the launch because a user who
    /// thinks in folders thinks in folders tomorrow too.
    @AppStorage(ChangedFilePresentation.storageKey) private var isTree = false

    var body: some View {
        HStack(spacing: InspectorLayout.gap) {
            ViewThatFits(in: .horizontal) {
                tabPicker.pickerStyle(.segmented)
                tabPicker.pickerStyle(.menu).fixedSize()
            }
            .labelsHidden()
            .controlSize(.small)

            Spacer(minLength: InspectorLayout.tight)

            Toggle(isOn: $isReviewing) {
                Label("Review changes", systemImage: "eye")
            }
            .labelStyle(.iconOnly)
            .toggleStyle(.button)
            .controlSize(.small)
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
            .controlSize(.small)
            .disabled(model.changedFiles.isEmpty)
            .help(isTree ? "Show the changed files as a flat list" : "Group the changed files by folder")

            Toggle(isOn: $isSideBySide) {
                Label("Side by side diff", systemImage: "rectangle.split.2x1")
            }
            .labelStyle(.iconOnly)
            .toggleStyle(.button)
            .controlSize(.small)
            .help(isSideBySide ? "Show a unified diff" : "Show the diff side by side")

            Menu {
                Button("Refresh", action: refresh)
                Divider()
                Button("Copy branch name", action: copyBranch)
                Button("Reveal worktree in Finder") { Reveal.inFinder(model.workspace.path) }
                Button("Open worktree in Editor") { Reveal.inEditor(model.workspace.path) }
                if let pullRequest = model.pullRequest {
                    Divider()
                    Button("Open pull request") { GitHubBridge.open(pullRequest.url) }
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
        }
        .padding(.horizontal, InspectorLayout.gap)
        .frame(height: InspectorLayout.barHeight)
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

    private func refresh() {
        Task {
            await model.refreshChanges()
            await model.refreshPullRequest()
        }
    }

    private func copyBranch() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.workspace.branch, forType: .string)
    }
}
