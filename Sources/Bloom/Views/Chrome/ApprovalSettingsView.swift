import SwiftUI
import BloomCore

/// The Approvals pane: everything the user ever said "always allow" to, and the only way to take
/// one back.
///
/// It is not optional decoration. Offering a button that grants a rule forever is only safe if the
/// grant can be found again months later by somebody who has forgotten making it, so this pane is
/// what pays for the "Always allow" button existing at all. An approval you cannot find is an
/// approval you cannot revoke.
///
/// Grouped by project, because that is the scope a grant has. Bloom keeps them in its own database
/// keyed by repository rather than in the CLI's `localSettings`, which writes
/// `.claude/settings.local.json` inside a worktree: gitignored, not shared with the repository,
/// and deleted when the workspace is archived. A rule granted "forever" would have quietly stopped
/// applying the moment the workspace it was granted in went away.
///
/// The rule text is the CLI's own `ruleContent`, never a rewording. Showing anything else would
/// mean somebody revoking a rule they never read.
struct ApprovalSettingsView: View {
    @Environment(AppModel.self) private var app

    @State private var grants: [PermissionGrant] = []
    @State private var isLoaded = false
    /// The grant a second press would remove. Revoking is one press and then one more, rather than
    /// a sheet: the action is cheap to undo (the next ask simply comes back) and a modal over a
    /// list of twenty rules would be worse than the mistake it prevents.
    @State private var confirming: PermissionGrantID?

    var body: some View {
        Form {
            if isLoaded, grants.isEmpty {
                Section {
                    Text("Nothing yet.")
                        .foregroundStyle(Palette.textSecondary)
                } footer: {
                    Text(
                        "When an agent asks to do something, one of the answers is to allow it for "
                        + "the whole project. Those rules are listed here, and this is where you take "
                        + "them back."
                    )
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                    Text(
                        "Bloom answers a question itself only when the agent proposes exactly one of "
                        + "these rules, character for character. Anything else is asked. Revoking "
                        + "takes effect on the next question, not the next launch."
                    )
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .task { await reload() }
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
        grants = (try? await store.permissionGrants()) ?? []
        isLoaded = true
    }

    private func revoke(_ grant: PermissionGrant) async {
        guard let store = app.store else { return }
        try? await store.deletePermissionGrant(id: grant.id)
        confirming = nil
        await reload()
    }
}
