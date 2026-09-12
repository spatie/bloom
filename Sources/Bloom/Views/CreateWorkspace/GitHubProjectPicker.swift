import SwiftUI
import BloomCore

struct GitHubProjectPicker: View {
    let isRemote: Bool
    let onSelect: (Repo) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var repositories: [GitHubRepositoryListing] = []
    @State private var page = 1
    @State private var isLoading = false
    @State private var isImporting = false
    @State private var problem: String?
    @State private var selected: String?
    @State private var hasMore = false

    private var backend: ProjectCreationBackend { ProjectCreationBackend(app: app, isRemote: isRemote) }
    private var key: String { "\(isRemote)-\(String(reflecting: app.remoteServer.endpoint))-\(query)-\(page)" }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            Text("Choose a GitHub repository").font(Typo.heading)
            TextField("Search GitHub repositories", text: $query)
                .textFieldStyle(.roundedBorder)
                .onChange(of: query) { _, _ in page = 1; selected = nil }
            List(repositories, selection: $selected) { repo in
                HStack {
                    Image(systemName: repo.isPrivate ? "lock" : "folder")
                    VStack(alignment: .leading) {
                        Text(repo.nameWithOwner)
                        if let description = repo.description, !description.isEmpty {
                            Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .tag(repo.id)
            }
            .frame(height: 290)
            if let problem { Text(problem).foregroundStyle(Palette.negative).font(Typo.caption).textSelection(.enabled) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if isLoading || isImporting { ProgressView().controlSize(.small) }
                Spacer()
                if hasMore { Button("Load More") { page += 1 }.disabled(isLoading) }
                Button(isImporting ? "Cloning…" : "Use Repository") { importSelection() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil || isLoading)
            }
        }
        .padding(Metrics.gutter)
        .frame(width: 560)
        .disabled(isImporting)
        .interactiveDismissDisabled(isImporting)
        .task(id: key) {
            isLoading = true
            problem = nil
            if page == 1 { repositories = [] }
            do {
                try await Task.sleep(for: .milliseconds(250))
                let values = try await backend.repositories(query: query, page: page)
                guard !Task.isCancelled else { return }
                repositories += values.filter { value in !repositories.contains { $0.id == value.id } }
                hasMore = values.count == 50 && page < 20
                if repositories.isEmpty { problem = "No matching repositories." }
            } catch { if !Task.isCancelled { problem = error.localizedDescription } }
            if !Task.isCancelled { isLoading = false }
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
