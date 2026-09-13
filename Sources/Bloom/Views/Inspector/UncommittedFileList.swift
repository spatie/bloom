import SwiftUI
import BloomCore

/// Selection includes the staging layer: clicking the second row for a partially staged file
/// must not jump back to the first row's patch just because the paths match.
struct UncommittedFileList: View {
    let model: WorkspaceModel
    @State private var query = ""
    @State private var keyboard = ListKeyboard()
    @State private var hasKeyboard = false
    @State private var armToken = 0

    private var files: [ChangedFile] {
        ChangedFileFilter.apply(to: model.changedFiles, needle: FileNeedle.canonical(query)) ?? model.changedFiles
    }

    var body: some View {
        VStack(spacing: 0) {
            if !model.changedFiles.isEmpty {
                InspectorFilterField(query: $query, onEscape: { query = "" }, onReturn: {
                    if let file = files.first { select(file) }
                })
                Hairline()
            }
            if model.isLoadingChanges || !model.hasReadChanges {
                LoadingView("Reading uncommitted changes")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.changesError {
                EmptyStateView(
                    glyph: "exclamationmark.triangle", title: "Could not read changes", message: error,
                    actionTitle: "Try again", action: { Task { await model.refreshChanges() } }
                )
            } else if model.changedFiles.isEmpty {
                EmptyStateView(
                    glyph: "checkmark.circle", title: "No uncommitted changes",
                    message: "Everything in this worktree is committed."
                )
            } else if files.isEmpty {
                EmptyStateView(glyph: "magnifyingglass", title: "No files match", message: "Try another filename.")
            } else {
                fileList
            }
        }
    }

    private var fileList: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(ChangeLayer.allCases, id: \.self) { layer in
                        let group = files.filter { $0.layer == layer }
                        if layer != .conflicted || !group.isEmpty {
                            Section {
                                ForEach(group) { file in row(file) }
                            } header: {
                                HStack {
                                    Text(layer.title)
                                    Spacer()
                                    Text("\(group.count)").monospacedDigit()
                                }
                                .font(Typo.caption).foregroundStyle(Palette.textSecondary)
                                .padding(.horizontal, InspectorLayout.inset)
                                .padding(.vertical, Metrics.spacingSmall)
                                .background(Palette.surfaceSunken)
                            }
                        }
                    }
                }
            }
            .onChange(of: model.selectedChangeID) { _, id in
                if let id { reader.scrollTo(id) }
            }
        }
        .listKeyboard(hasKeyboard: $hasKeyboard, armToken: armToken, onKey: handle)
        .accessibilityLabel("Uncommitted files by staging state")
    }

    private func row(_ file: ChangedFile) -> some View {
        HoverRow(isSelected: model.selectedChangeID == file.id, isFocused: hasKeyboard) {
            Button { select(file) } label: {
                HStack(alignment: .top, spacing: Metrics.spacingSmall) {
                    Text(file.change.rawValue).font(Typo.micro)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.filename).font(Typo.label).lineLimit(1)
                        if !file.directory.isEmpty {
                            Text(file.directory).font(Typo.micro).opacity(0.7)
                                .lineLimit(1).truncationMode(.head)
                        }
                    }
                    Spacer(minLength: 0)
                    if !file.isBinary, file.layer != .conflicted {
                        Text("+\(file.additions)")
                        Text("−\(file.deletions)")
                    }
                }
                .font(Typo.micro).monospacedDigit()
                .padding(.horizontal, Metrics.spacingSmall)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(file.layer?.title ?? ""): \(file.path)\n\(file.layer?.comparison ?? "")")
            .accessibilityLabel("\(file.layer?.title ?? ""), \(file.path), \(file.additions) additions, \(file.deletions) deletions")
            .accessibilityAddTraits(model.selectedChangeID == file.id ? .isSelected : [])
        }
        .padding(.horizontal, Metrics.spacingSmall)
        .id(file.id)
    }

    private func select(_ file: ChangedFile) {
        model.selectedChangeLayer = file.layer
        model.selectedFilePath = file.path
        FileReview.open(path: file.path, in: model)
        armToken += 1
    }

    private func handle(_ key: ListKey) -> Bool {
        let available = files
        let index = available.firstIndex { $0.id == model.selectedChangeID }
        switch keyboard.outcome(for: key, titles: available.map(\.filename), current: index) {
        case .move(let row): select(available[row]); return true
        case .activate:
            if let index { select(available[index]) }
            return true
        case .handled: return true
        case .ignored: return false
        }
    }
}
