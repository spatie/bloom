import SwiftUI
import AppKit
import BatonCore

/// The right hand column: what the agent changed, and what GitHub thinks of it.
///
/// Everything here is a thin arrangement of the pieces below it. The tab row owns two settings
/// that its children need (the diff layout, and review mode) because both are chrome level
/// choices that outlive whichever file happens to be selected.
struct InspectorView: View {
    private let model: WorkspaceModel

    init(model: WorkspaceModel) {
        self.model = model
    }

    @AppStorage(DiffLayoutSetting.storageKey) private var isSideBySide = false
    @State private var isReviewing = false

    var body: some View {
        VStack(spacing: 0) {
            PullRequestBar(model: model)
            Hairline()
            toolbar
            Hairline()
            content
        }
        .background(Palette.surface)
    }

    // MARK: - Toolbar

    /// A real segmented control rather than three hand drawn buttons. It is the AppKit control for
    /// exactly this choice, so it gets the right metrics, the right selection colour and the right
    /// behaviour when the window goes inactive, at every width, for free.
    private var toolbar: some View {
        HStack(spacing: InspectorLayout.gap) {
            Picker("Inspector view", selection: tabSelection) {
                ForEach(InspectorTab.allCases, id: \.self) { tab in
                    Text(title(for: tab)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            Spacer(minLength: InspectorLayout.tight)

            Toggle(isOn: $isReviewing) {
                Image(systemName: "eye")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .disabled(model.changedFiles.isEmpty)
            .help("Review the changes one file at a time")
            .onChange(of: isReviewing) { _, reviewing in
                guard reviewing, model.selectedFilePath == nil else { return }
                model.selectedFilePath = model.changedFiles.first?.path
            }

            Toggle(isOn: $isSideBySide) {
                Image(systemName: "rectangle.split.2x1")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help(isSideBySide ? "Show a unified diff" : "Show the diff side by side")

            Menu {
                Button("Refresh") {
                    Task {
                        await model.refreshChanges()
                        await model.refreshPullRequest()
                    }
                }
                Divider()
                Button("Copy branch name") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.workspace.branch, forType: .string)
                }
                Button("Reveal worktree in Finder") { Reveal.inFinder(model.workspace.path) }
                Button("Open worktree in Editor") { Reveal.inEditor(model.workspace.path) }
                if let pullRequest = model.pullRequest {
                    Divider()
                    Button("Open pull request") { GitHubBridge.open(pullRequest.url) }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .controlSize(.small)
            .fixedSize()
            .help("More for this worktree")
        }
        .padding(.horizontal, InspectorLayout.gap)
        .frame(height: InspectorLayout.barHeight)
    }

    /// The model is observable rather than a source of truth this view owns, so the picker reads
    /// and writes it directly instead of keeping a second copy that could drift.
    private var tabSelection: Binding<InspectorTab> {
        Binding(get: { model.inspectorTab }, set: { model.inspectorTab = $0 })
    }

    private func title(for tab: InspectorTab) -> String {
        guard tab == .changes, !model.changedFiles.isEmpty else { return tab.rawValue }
        return "\(tab.rawValue) (\(model.changedFiles.count))"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.inspectorTab {
        case .allFiles:
            FileTreeView(model: model)
        case .changes:
            changes
        case .checks:
            ChecksView(model: model)
        }
    }

    @ViewBuilder
    private var changes: some View {
        if isReviewing, let file = model.selectedFile ?? model.changedFiles.first {
            review(file)
        } else {
            VSplitLayout(
                top: { ChangedFileList(model: model) },
                bottom: {
                    if let file = model.selectedFile {
                        DiffView(model: model, file: file)
                    }
                },
                hasBottom: model.selectedFile != nil
            )
        }
    }

    /// Review mode drops the list and walks the files one at a time, which is how a diff is
    /// actually read once you have decided to read all of it.
    private func review(_ file: ChangedFile) -> some View {
        let index = model.changedFiles.firstIndex { $0.path == file.path } ?? 0
        let total = max(model.changedFiles.count, 1)

        return VStack(spacing: 0) {
            HStack(spacing: InspectorLayout.gap) {
                Button {
                    step(-1, from: index)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .disabled(index == 0)
                .help("Previous file")

                Button {
                    step(1, from: index)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .disabled(index >= total - 1)
                .help("Next file")

                Text(file.filename)
                    .font(Typo.labelEmphasis)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: InspectorLayout.tight)

                Text("\(index + 1) of \(total)")
                    .font(Typo.micro)
                    .monospacedDigit()
                    .foregroundStyle(Palette.textTertiary)
                DiffStatLabel(additions: file.additions, deletions: file.deletions, compact: true)
            }
            .padding(.horizontal, InspectorLayout.inset)
            .frame(height: Metrics.rowHeight)
            .background(Palette.surfaceSunken)

            Hairline()
            DiffView(model: model, file: file)
        }
    }

    private func step(_ delta: Int, from index: Int) {
        let target = index + delta
        guard model.changedFiles.indices.contains(target) else { return }
        model.selectedFilePath = model.changedFiles[target].path
    }
}

/// The inspector's spacing scale.
///
/// One set of numbers rather than a literal per call site, because three stacked panes only read
/// as one column if their rows, insets and gutters agree.
enum InspectorLayout {
    /// Between two things that belong to each other.
    static let tight: CGFloat = 2
    /// Between controls in a row.
    static let gap: CGFloat = 6
    /// The inset a list row keeps from the edge of the pane.
    static let inset: CGFloat = 10
    /// The pull request strip and the toolbar under it.
    static let barHeight: CGFloat = 32
    /// A meaning colour used as a background rather than as ink. One value, so a green badge and a
    /// blue chip carry the same weight.
    static let tintOpacity: Double = 0.12
    /// Status glyphs share one box, so the names beside them line up whichever symbol lands in it.
    static let glyphWidth: CGFloat = 16
    /// One level of indent in the file tree.
    static let indentStep: CGFloat = 12
    /// How much room a list keeps once a detail pane has opened beneath it.
    static let listHeight: CGFloat = 220
}
