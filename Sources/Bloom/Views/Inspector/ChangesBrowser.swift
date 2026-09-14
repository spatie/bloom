import SwiftUI
import BloomCore

/// Changes keeps its full file-list height; only the History tab shares that space with commits.
struct ChangesBrowser: View {
    let model: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            ChangesHistoryList(model: model)
            Hairline()
            Group {
                if model.inspectorTab == .history, !model.diffScope.isHistorical {
                    Text("Select a commit to review its changed files.")
                        .font(Typo.caption).foregroundStyle(Palette.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(InspectorLayout.inset)
                } else if model.diffScope == .uncommitted {
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
        model.inspectorTab == .history ? model.branchCommits.commits.map(DiffScope.commit) : [.all, .uncommitted]
    }

    var body: some View {
        ScrollViewReader { reader in
            VStack(spacing: 0) {
                if model.inspectorTab == .history {
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
                } else {
                    scopeMenu
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
        .accessibilityLabel(model.inspectorTab == .history ? "Commit history, newest first" : "Change scope")
    }

    private var scopeMenu: some View {
        Menu {
            ForEach(scopes, id: \.self) { scope in
                // Reselecting the current scope also reopens its review in the centre pane.
                Toggle(scope.title, isOn: Binding(
                    get: { model.diffScope == scope },
                    set: { _ in select(scope) }
                ))
            }
        } label: {
            Label(
                model.diffScope.title,
                systemImage: model.diffScope == .uncommitted ? "pencil.line" : "square.stack.3d.up"
            )
            .font(Typo.label)
            .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, InspectorLayout.inset)
        .frame(height: InspectorLayout.barHeight)
        .accessibilityLabel("Change scope")
        .accessibilityValue(model.diffScope.title)
    }

    private func select(_ scope: DiffScope) {
        model.setDiffScope(scope)
        FileReview.open(path: "", in: model)
        if let tab = CenterTabStore.shared.review(for: model.workspace.id) {
            CenterTabStore.shared.setShowsAllFiles(true, for: tab)
        }
        armToken += 1
    }

    private func handle(_ key: ListKey) -> Bool {
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
