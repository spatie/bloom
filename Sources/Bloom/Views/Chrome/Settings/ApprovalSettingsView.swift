import SwiftUI
import BloomCore

/// Permissions stay discoverable before the first project-wide approval is granted.
struct ApprovalSettingsView: View {
    @Environment(AppModel.self) private var app

    @Binding var defaults: AppDefaults
    var isReady: Bool
    @State private var failure: String?

    private static let permissionModes = PermissionMode.allCases.filter { $0 != .autoReview }

    @State private var grants: [PermissionGrant] = []
    @State private var isLoaded = false
    /// The grant a second press would remove. Revoking is one press and then one more, rather than
    /// a sheet: the action is cheap to undo (the next ask simply comes back) and a modal over a
    /// list of twenty rules would be worse than the mistake it prevents.
    @State private var confirming: PermissionGrantID?

    var body: some View {
        Form {
            Section {
                Picker("Default permission mode", selection: $defaults.permissionMode) {
                    ForEach(Self.permissionModes, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .disabled(!isReady)
            } header: {
                Text("New sessions")
            } footer: {
                Text("Controls what an agent can do without asking. Plan mode in Sessions takes priority. Existing sessions keep their permissions.")
                    .settingsFootnote()
            }

            if let failure {
                Section {
                    ErrorBanner(title: "Could not update approvals", message: failure) {
                        self.failure = nil
                    }
                    Button("Retry") { Task { await reload() } }
                }
            }

            if !isLoaded {
                Section { LoadingView("Loading saved approvals") }
            } else if grants.isEmpty {
                Section {
                    Label("No saved approvals", systemImage: "hand.raised")
                        .foregroundStyle(Palette.textSecondary)
                } header: {
                    Text("Project approvals")
                } footer: {
                    Text("Approvals you allow for an entire project appear here. You can revoke them at any time.")
                        .settingsFootnote()
                }
            }

            ForEach(projects, id: \.id) { repo in
                Section(repo.name) {
                    ForEach(grants(in: repo.id)) { grant in
                        row(grant)
                    }
                }
            }

            if !grants.isEmpty {
                Section {
                    EmptyView()
                } footer: {
                    Text("Revoking takes effect on the next question, not the next launch.")
                        .settingsFootnote()
                }
            }
        }
        .settingsForm()
        .task {
            await reload()
            guard let store = app.store else { return }
            for await _ in store.changes(of: [.permissionGrants]) {
                await reload()
            }
        }
    }

    // MARK: Rows

    private func row(_ grant: PermissionGrant) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing) {
            VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                // The CLI's spelling, in the code face, because that is what it is.
                Text(grant.displayText)
                    .font(Typo.codeSmall)
                    .foregroundStyle(Palette.textPrimary)
                    .textSelection(.enabled)

                Text(provenance(grant))
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Metrics.spacing)

            if confirming == grant.id {
                Button("Revoke", role: .destructive) {
                    Task { await revoke(grant) }
                }
                .controlSize(.small)
                Button("Cancel") { confirming = nil }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            } else {
                Button("Revoke") { confirming = grant.id }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, Metrics.spacingTight)
    }

    /// When it was granted, what it has done since, and what was on screen at the time.
    ///
    /// The use count is here because it is the one number that says whether a rule is earning its
    /// place: a rule used sixty times is why the feature is bearable, and one used never is a
    /// decision somebody can undo without losing anything.
    private func provenance(_ grant: PermissionGrant) -> String {
        var parts = ["Granted \(Self.relative.localizedString(for: grant.grantedAt, relativeTo: Date()))"]

        if grant.useCount > 0 {
            parts.append(grant.useCount == 1 ? "used once" : "used \(grant.useCount) times")
        } else {
            parts.append("never used")
        }

        var line = parts.joined(separator: " · ")
        if !grant.grantedFor.isEmpty {
            // What the ask was actually about. A rule on its own is often not enough to remember a
            // decision by, especially a wildcard one.
            line += "\nFor: \(grant.grantedFor)"
        }
        return line
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    // MARK: Data

    /// Only projects that have granted something, so the pane is a list of decisions rather than a
    /// list of projects most of which say nothing.
    private var projects: [Repo] {
        let granted = Set(grants.map(\.repoID))
        return app.repos.filter { granted.contains($0.id) }
    }

    private func grants(in repoID: RepoID) -> [PermissionGrant] {
        grants.filter { $0.repoID == repoID }
    }

    private func reload() async {
        guard let store = app.store else { return }
        do {
            grants = try await store.permissionGrants()
            isLoaded = true
            failure = nil
        } catch {
            failure = error.readableMessage
        }
    }

    private func revoke(_ grant: PermissionGrant) async {
        guard let store = app.store else { return }
        do {
            try await store.deletePermissionGrant(id: grant.id)
            confirming = nil
            await reload()
        } catch {
            failure = error.readableMessage
        }
    }
}
