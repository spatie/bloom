import SwiftUI
import BloomCore

/// Keep the file list's space until history is requested. The collapsed header has only its
/// natural height; hiding rows inside the old split view would leave their empty pane behind.
struct ChangesBrowser: View {
    let model: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            ChangesHistoryList(model: model)
            Hairline()
            Group {
                if model.diffScope == .uncommitted {
                    UncommittedFileList(model: model)
                } else {
                    ChangedFileList(model: model)
                }
            }
            .frame(minHeight: 120, maxHeight: .infinity)
        }
    }
}

struct ChangesHistoryList: View {
    let model: WorkspaceModel
    @State private var keyboard = ListKeyboard()
    @State private var hasKeyboard = false
    @State private var armToken = 0

    private var scopes: [DiffScope] {
        [.all, .uncommitted] + (model.showsCommitHistory ? model.branchCommits.commits.map(DiffScope.commit) : [])
    }

    var body: some View {
        ScrollViewReader { reader in
            VStack(spacing: 0) {
                scopeRow(.all, glyph: "square.stack.3d.up")
                scopeRow(.uncommitted, glyph: "pencil.line")
                Hairline()
                historyDisclosure
                if model.showsCommitHistory {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(model.branchCommits.commits) { commit in
                                HoverRow(isSelected: model.diffScope == .commit(commit), isFocused: hasKeyboard) {
                                    Button { select(.commit(commit)) } label: {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(commit.subject).font(Typo.label).lineLimit(2)
                                            Text(commit.author).font(Typo.caption).lineLimit(1).opacity(0.8)
                                            HStack(spacing: Metrics.spacingSmall) {
                                                Text(commit.abbreviated).monospaced()
                                                Text(commit.date, format: .dateTime.day().month(.abbreviated).hour().minute())
                                            }
                                            .font(Typo.micro).opacity(0.7)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, Metrics.spacingSmall)
                                        .padding(.vertical, 7)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .help("\(commit.sha)\n\(commit.author) · \(commit.date.formatted())\n\(commit.subject)")
                                    .accessibilityElement(children: .combine)
                                    .accessibilityAddTraits(model.diffScope == .commit(commit) ? .isSelected : [])
                                }
                                .padding(.horizontal, Metrics.spacingSmall)
                                .id(DiffScope.commit(commit))
                            }
                            if model.branchCommits.isTruncated {
                                Button("Load earlier commits", action: model.loadMoreCommits)
                                    .controlSize(.small).padding(InspectorLayout.inset)
                            } else if model.hasReadBranchCommits, model.branchCommits.commits.isEmpty {
                                Text("No commits unique to this branch.")
                                    .font(Typo.caption).foregroundStyle(Palette.textSecondary)
                                    .padding(InspectorLayout.inset)
                            } else if !model.hasReadBranchCommits, model.historyError == nil {
                                ProgressView().controlSize(.small).padding(InspectorLayout.inset)
                                    .accessibilityLabel("Reading commit history")
                            }
                            if let error = model.historyError {
                                VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                                    Text(error).font(Typo.caption).foregroundStyle(Palette.textSecondary)
                                    Button("Retry history") { Task { await model.refreshChanges() } }
                                        .controlSize(.small)
                                }
                                .padding(InspectorLayout.inset)
                            }
                        }
                    }
                    .frame(minHeight: 80, idealHeight: 180, maxHeight: 240)
                    .onChange(of: model.diffScope) { _, scope in
                        if hasKeyboard { reader.scrollTo(scope) }
                    }
                }
                if let notice = model.historyNotice {
                    Text(notice).font(Typo.caption).foregroundStyle(Palette.textSecondary)
                        .padding(InspectorLayout.inset)
                }
                if let note = model.scopeNote {
                    Text(note).font(Typo.caption).foregroundStyle(Palette.textSecondary)
                        .padding(InspectorLayout.inset)
                }
            }
        }
        .background(Palette.surface)
        .listKeyboard(hasKeyboard: $hasKeyboard, armToken: armToken, onKey: handle)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Review history, newest commits first")
    }

    private var historyDisclosure: some View {
        Button {
            model.showsCommitHistory.toggle()
        } label: {
            HStack(spacing: Metrics.spacingSmall) {
                Image(systemName: model.showsCommitHistory ? "chevron.down" : "chevron.right")
                    .font(Typo.micro)
                    .accessibilityHidden(true)
                Text("Commit history")
                Spacer(minLength: 0)
                if case .commit(let commit) = model.diffScope {
                    Text(commit.abbreviated).monospaced()
                }
            }
            .font(Typo.caption)
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, InspectorLayout.inset)
            .padding(.vertical, Metrics.spacingSmall)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.showsCommitHistory ? "Hide commit history" : "Show commit history")
        .accessibilityValue(model.showsCommitHistory ? "Expanded" : "Collapsed")
        .help(model.showsCommitHistory ? "Hide the commit list" : "Show this branch's commits")
    }

    private func scopeRow(_ scope: DiffScope, glyph: String) -> some View {
        HoverRow(isSelected: model.diffScope == scope, isFocused: hasKeyboard) {
            Button { select(scope) } label: {
                Label(scope.title, systemImage: glyph)
                    .font(Typo.label)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Metrics.spacingSmall)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(model.diffScope == scope ? .isSelected : [])
        }
        .padding(.horizontal, Metrics.spacingSmall)
        .padding(.vertical, 2)
        .id(scope)
    }

    private func select(_ scope: DiffScope) {
        if scope != model.diffScope {
            model.setDiffScope(scope)
            FileReview.open(path: "", in: model)
            if let tab = CenterTabStore.shared.review(for: model.workspace.id) {
                CenterTabStore.shared.setShowsAllFiles(true, for: tab)
            }
        }
        armToken += 1
    }

    private func handle(_ key: ListKey) -> Bool {
        if key == .right { model.showsCommitHistory = true; return true }
        if key == .left { model.showsCommitHistory = false; return true }
        let available = scopes
        let index = available.firstIndex(of: model.diffScope)
        switch keyboard.outcome(for: key, titles: available.map(\.title), current: index) {
        case .move(let row): select(available[row]); return true
        case .activate:
            if let index { select(available[index]) }
            return true
        case .handled: return true
        case .ignored: return false
        }
    }
}
