import SwiftUI
import BloomCore

struct GitHubProjectPicker: View {
    let isRemote: Bool
    let onSelect: (Repo) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""
    @State private var repositories: [GitHubRepositoryListing] = []
    @State private var page = 1
    @State private var isLoading = false
    @State private var isImporting = false
    @State private var problem: String?
    @State private var selected: String?
    @State private var hasMore = false
    @State private var needsServerSignIn = false
    @State private var refreshID = UUID()

    private var backend: ProjectCreationBackend { ProjectCreationBackend(app: app, isRemote: isRemote) }
    private var key: String { "\(isRemote)-\(String(reflecting: app.remoteServer.endpoint))-\(query)-\(page)-\(refreshID)" }

    private var listState: GitHubRepositoryListState {
        GitHubRepositoryListState.resolve(
            rowCount: repositories.count,
            query: query,
            page: page,
            isLoading: isLoading,
            problem: problem,
            needsServerSignIn: needsServerSignIn,
            serverName: isRemote ? app.remoteServer.displayName : nil
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            Text("Choose a GitHub repository").font(Typo.heading)
            TextField("Search GitHub repositories", text: $query)
                .textFieldStyle(.roundedBorder)
                .onChange(of: query) { _, _ in page = 1; selected = nil }
            list
            // Only a failure beside rows lands here: the next page, or the clone. A failure with
            // nothing to show is drawn in the list itself, where the eye already is.
            if let problem, !repositories.isEmpty {
                Text(problem).foregroundStyle(Palette.negative).font(Typo.caption).textSelection(.enabled)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Refresh") { page = 1; selected = nil; refreshID = UUID() }.disabled(isLoading)
                Spacer()
                if hasMore { Button("Load More") { page += 1 }.disabled(isLoading) }
                if isImporting { ProgressView().controlSize(.small) }
                Button(isImporting ? "Creating Project…" : "Create Project") { importSelection() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil || isLoading)
            }
        }
        .padding(Metrics.gutter)
        .frame(width: 560)
        .disabled(isImporting)
        .interactiveDismissDisabled(isImporting)
        .task(id: key) { await load() }
    }

    private var list: some View {
        let state = listState
        // Rows from the previous search stay while the next one runs, dimmed and not selectable,
        // because blanking them is what made the window look empty. They are replaced in one step
        // when the answer arrives, so no stale row can be chosen.
        let isReplacing: Bool = if case .rows(busy: .some(let busy)) = state { busy != .loadingMore } else { false }
        return List(repositories, selection: $selected) { repo in
            GitHubRepositoryRow(repo: repo)
                .tag(repo.id)
        }
        .opacity(isReplacing ? 0.45 : 1)
        .disabled(isReplacing)
        .frame(height: 290)
        .overlay { emptyOverlay(state) }
        .overlay(alignment: .bottom) {
            if case .rows(busy: .some(let busy)) = state {
                GitHubRepositoryBusyNote(sentence: busy.sentence)
                    .padding(.bottom, Metrics.gutter)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private func emptyOverlay(_ state: GitHubRepositoryListState) -> some View {
        switch state {
        case .rows:
            EmptyView()
        case .placeholder(let busy):
            GitHubRepositoryPlaceholder(sentence: busy.sentence)
        case .signInOnServer:
            ContentUnavailableView {
                Label(state.title, systemImage: state.symbol)
            } description: {
                Text("GitHub access is checked on \(app.remoteServer.displayName). Your Mac’s sign-in is separate.")
            } actions: {
                Button("Sign In on Server…") { openWindow(id: ServerAccountsWindow.id) }
            }
        case .failed:
            EmptyStateView(glyph: state.symbol, title: state.title, message: state.message, actionTitle: "Try Again") {
                page = 1
                refreshID = UUID()
            }
            .textSelection(.enabled)
        case .noRepositories, .noMatch:
            EmptyStateView(glyph: state.symbol, title: state.title, message: state.message)
        }
    }

    private func load() async {
        isLoading = true
        needsServerSignIn = false
        let isFirstPage = page == 1
        if isFirstPage { selected = nil }
        do {
            try await Task.sleep(for: .milliseconds(250))
            let values = try await backend.repositories(query: query, page: page)
            guard !Task.isCancelled else { return }
            problem = nil
            if isFirstPage {
                repositories = values
            } else {
                repositories += values.filter { value in !repositories.contains { $0.id == value.id } }
            }
            hasMore = values.count == 50 && page < 20
        } catch {
            guard !Task.isCancelled else { return }
            problem = error.localizedDescription
            // A first page that failed has no rows of its own, and the ones still showing answer a
            // different search, so they go rather than sit above an error that is not about them.
            if isFirstPage { repositories = []; hasMore = false }
        }
        if !Task.isCancelled, isRemote, repositories.isEmpty {
            await checkServerSignIn()
        }
        if !Task.isCancelled { isLoading = false }
    }

    @MainActor private func checkServerSignIn() async {
        do {
            let result = try await app.remoteServer.read(.diagnostics)
            guard !Task.isCancelled, case .diagnostics(let report) = result else { return }
            needsServerSignIn = report.checks.contains { $0.id == .github && $0.status == .attention }
        } catch {
            // A failed connection does not prove missing auth.
            if !Task.isCancelled && problem == nil { problem = error.localizedDescription }
        }
    }

    private func importSelection() {
        guard let selected else { return }
        isImporting = true
        problem = nil
        let backend = backend
        Task {
            defer { isImporting = false }
            do { let repo = try await backend.importGitHub(selected); onSelect(repo); dismiss() } catch { problem = error.localizedDescription }
        }
    }
}

/// One repository in the list. Its own type so the placeholder below can be drawn to the same
/// measure: a glyph, a name and a one line description.
private struct GitHubRepositoryRow: View {
    let repo: GitHubRepositoryListing

    var body: some View {
        HStack {
            Image(systemName: repo.isPrivate ? "lock" : "folder")
            VStack(alignment: .leading) {
                Text(repo.nameWithOwner)
                if let description = repo.description, !description.isEmpty {
                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

/// What fills the list while the first answer is on its way.
///
/// It was an empty white box for as long as `gh` took, several seconds on a remote server, with the
/// only sign of work a small spinner in the footer. Placeholder rows in the shape of the real ones
/// say that a list is coming and roughly what it will look like, and the sentence says which
/// question is being asked, so a search does not read as a fresh load.
///
/// The rows breathe on `BusyDot.period` so they keep time with every other busy mark in the app.
/// It is a SwiftUI animation rather than a layer one, which `BusyPulse` argues against for the main
/// window; the cost there scales with the hosting window, and this is a 560 point sheet that only
/// animates until the answer arrives. Under Reduce Motion the rows hold still at the lower tint.
private struct GitHubRepositoryPlaceholder: View {
    let sentence: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBright = false

    /// Varied so the rows read as names of different lengths rather than a striped pattern.
    private static let widths: [(name: CGFloat, description: CGFloat)] = [
        (0.42, 0.70), (0.30, 0.55), (0.50, 0.78), (0.36, 0.48), (0.46, 0.64), (0.28, 0.58)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Metrics.gutter / 2) {
                ProgressView().controlSize(.small)
                Text(sentence)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, Metrics.gutter * 0.75)

            GeometryReader { proxy in
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Self.widths.indices, id: \.self) { index in
                        row(Self.widths[index], width: proxy.size.width)
                    }
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .opacity(reduceMotion ? 0.6 : (isBright ? 1 : 0.45))
            .animation(
                reduceMotion ? nil : .easeInOut(duration: BusyDot.period / 2).repeatForever(autoreverses: true),
                value: isBright
            )
            .onAppear { isBright = true }
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(sentence)
    }

    private func row(_ widths: (name: CGFloat, description: CGFloat), width: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 3).frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 5) {
                Capsule().frame(width: width * widths.name, height: 10)
                Capsule().frame(width: width * widths.description, height: 8).opacity(0.7)
            }
        }
        .foregroundStyle(.quaternary)
    }
}

/// The note over rows that are still showing while the next answer runs, in place of the footer
/// spinner that was the only sign of it before.
private struct GitHubRepositoryBusyNote: View {
    let sentence: String

    var body: some View {
        HStack(spacing: Metrics.gutter / 2) {
            ProgressView().controlSize(.mini)
            Text(sentence)
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}
