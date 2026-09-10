import SwiftUI
import BloomCore

/// Commands stay beside the file, so the same controls work in a split pane and in a pinned tab.
struct SourceTools<Model: WorkspacePaneModel>: View {
    let model: Model
    let path: String
    @Bindable var state: SourceEditorState
    @State private var panel: SourceSearchPanel.Mode?
    @State private var showsLine = false
    @State private var line = ""
    private var navigation: SourceNavigation { model.paneStores.sourceNavigation }

    var body: some View {
        HStack(spacing: InspectorLayout.gap) {
            Button { navigation.move(-1, in: model) } label: { Image(systemName: "chevron.left") }
                .disabled(navigation.histories[model.workspace.id]?.canGoBack != true)
                .help("Go back")
            Button { navigation.move(1, in: model) } label: { Image(systemName: "chevron.right") }
                .disabled(navigation.histories[model.workspace.id]?.canGoForward != true)
                .help("Go forward")
            Button("Find") { state.find() }
                .help("Find in this file (Command-F)")
            Menu("Navigate") {
                Button("Search workspace code…") { panel = .workspace }
                    .disabled(model.localWorkspaceModel == nil)
                Button("Jump to symbol…") { panel = .symbols }
                    .disabled(model.localWorkspaceModel == nil)
                Button("Go to line…") { line = ""; showsLine = true }
                Button("Go to Definition") {
                    if let local = model.localWorkspaceModel {
                        SourceActions.definition(at: state.selection.location, path: path, model: local, state: state)
                    }
                }.disabled(model.localWorkspaceModel == nil)
                Divider()
                Button("Ask about selected code") {
                    if let local = model.localWorkspaceModel { SourceActions.ask(path: path, model: local, state: state) }
                }.disabled(state.selection.length == 0 || model.localWorkspaceModel == nil)
            }.menuStyle(.borderlessButton).fixedSize()
                .popover(isPresented: $showsLine) {
                    VStack(alignment: .leading, spacing: Metrics.spacing) {
                        Text("Go to line").font(Typo.bodyEmphasis)
                        TextField("Line:column", text: $line).onSubmit(goToLine)
                            .frame(width: 160)
                        Button("Go", action: goToLine).keyboardShortcut(.defaultAction)
                            .disabled(Int(line.split(separator: ":").first ?? "") == nil)
                    }.padding(Metrics.inset)
                }
            Spacer(minLength: 0)
            Menu {
                Button("Auto-detect") { state.languageOverride = nil }
                Divider()
                ForEach(Language.allCases, id: \.self) { language in
                    Button(language.rawValue) { state.languageOverride = language }
                }
            } label: {
                Text((state.languageOverride ?? Language.detect(path: path)).rawValue)
            }.fixedSize()
            Toggle(isOn: $state.wraps) { Image(systemName: "return") }
                .toggleStyle(.button).help("Wrap long lines")
            Text("\(state.line):\(state.column)")
                .monospacedDigit().foregroundStyle(Palette.textSecondary)
                .help("Line and column")
        }
        .buttonStyle(.borderless)
        .font(Typo.caption)
        .controlSize(.small)
        .padding(.horizontal, InspectorLayout.inset)
        .frame(height: InspectorLayout.barHeight)
        .sheet(item: $panel) { mode in
            if let local = model.localWorkspaceModel { SourceSearchPanel(model: local, path: path, state: state, mode: mode) }
        }
    }

    private func goToLine() {
        guard let first = line.split(separator: ":").first, let number = Int(first), number > 0 else { return }
        let parts = line.split(separator: ":")
        let column = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
        model.paneStores.sourceNavigation.visit(CodeLocation(path: path, line: state.line, column: state.column), in: model)
        let location = CodeLocation(path: path, line: number, column: column)
        model.paneStores.sourceNavigation.visit(location, in: model)
        state.go(to: location)
        showsLine = false
    }
}

struct SourceSearchPanel: View {
    enum Mode: String, Identifiable { case workspace, symbols; var id: String { rawValue } }
    let model: WorkspaceModel
    let path: String
    let state: SourceEditorState
    let mode: Mode
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [SourceMatch] = []
    @State private var loading = false
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            HStack {
                Text(mode == .workspace ? "Search workspace code" : "Jump to symbol").font(Typo.bodyEmphasis)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            TextField(mode == .workspace ? "Find text in workspace files" : "Filter symbols", text: $query)
                .textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit { if let first = results.first { open(first) } }
            if loading { ProgressView().controlSize(.small) }
            if let problem { Text(problem).foregroundStyle(Palette.negative) }
            if !loading, results.isEmpty {
                Text(query.isEmpty && mode == .workspace ? "Searches text in tracked and unignored files." : "No matches")
                    .foregroundStyle(Palette.textSecondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                    ForEach(results) { match in
                        Button { open(match) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(match.location.path):\(match.location.line)").font(Typo.caption)
                                    .foregroundStyle(Palette.textSecondary)
                                Text(match.text).font(Typo.code).lineLimit(2)
                                    .foregroundStyle(Palette.textPrimary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(Metrics.spacingSmall)
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(minHeight: 300)
            Text(mode == .workspace ? "Up to 200 matching lines. Files larger than 1 MB are skipped." : "Declarations in the current buffer.")
                .font(Typo.caption).foregroundStyle(Palette.textTertiary)
        }
        .padding(Metrics.inset).frame(width: 650, height: 470)
        .task { focused = true }
        .task(id: query) { await search() }
    }

    private func open(_ match: SourceMatch) {
        dismiss()
        FileReview.open(location: match.location, in: model)
    }

    private func search() async {
        results = []
        problem = nil
        loading = true
        defer { if !Task.isCancelled { loading = false } }
        do {
            try await Task.sleep(for: .milliseconds(180))
            let needle = query
            let root = model.workspace.path
            let source = state.textView?.string ?? ""
            let path = path
            let mode = mode
            let paths = mode == .workspace ? await FileIndex.shared.files(workspacePath: root) : []
            try Task.checkCancellation()
            let worker = Task.detached(priority: .userInitiated) {
                if mode == .symbols {
                    return SourceSearch.symbols(in: source, path: path).filter {
                        needle.isEmpty || $0.text.localizedCaseInsensitiveContains(needle)
                    }
                }
                return try SourceSearch.search(root: root, paths: paths, query: needle)
            }
            let matches = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            results = matches
        } catch is CancellationError {
            // The next query replaces these results.
        } catch { problem = error.localizedDescription }
    }
}
