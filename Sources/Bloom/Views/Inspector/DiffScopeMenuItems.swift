import SwiftUI
import BloomCore

/// The rows behind the Changes tab's scope control: the three things the list can be measuring
/// from.
///
/// A view of its own rather than a `@ViewBuilder` on the toolbar, for the reason `WorktreeMenuItems`
/// is one: a menu that lives inside another view's body cannot be photographed, and this one has a
/// list in it whose bounds are worth looking at.
///
/// No target branch picker, and that is a decision rather than an omission. Conductor offers one
/// because its menu has to say what the diff is measured against; Bloom already knows. A workspace
/// records its base branch when it is created, `Git.baseline` resolves it against both the local
/// branch and its remote-tracking copy, and it is the branch the pull request will target. A
/// second, diff-only target would either be a display that disagrees with the pull request or a
/// control that silently changes where the work is going to land.
struct DiffScopeMenuItems: View {
    let model: WorkspaceModel

    var body: some View {
        let scope = model.diffScope

        Section {
            row(.all, subtitle: "Everything measured from \(model.workspace.baseBranch)", scope: scope)
            row(.uncommitted, subtitle: "Everything not committed yet", scope: scope)
        }

        if !model.branchCommits.commits.isEmpty {
            Section("Since a commit on this branch") {
                ForEach(model.branchCommits.commits) { commit in
                    row(
                        .since(commit),
                        title: commit.subject,
                        subtitle: "\(commit.abbreviated) · \(commit.author) · \(Self.age.localizedString(for: commit.date, relativeTo: .now))",
                        scope: scope
                    )
                }
                // Said rather than left to be inferred. A menu that stops at fifty rows on a
                // branch with sixty commits is a menu that has quietly answered a question it was
                // not asked.
                if let note = model.branchCommits.truncationNote {
                    Divider()
                    Text(note)
                }
            }
        }
    }

    /// One row, ticked when it is the scope in force.
    ///
    /// A `Toggle` rather than a `Button` with a checkmark in its label: a menu draws the tick
    /// itself, in the place the platform puts it, and a checkmark glued to a title indents every
    /// other row to line up with it.
    private func row(
        _ target: DiffScope, title: String? = nil, subtitle: String, scope: DiffScope
    ) -> some View {
        Toggle(isOn: .init(
            get: { scope == target },
            // A menu row cannot be turned off by pressing it again. Pressing the row that is
            // already on is a press meaning "this one", so it stays where it is rather than
            // falling back to All changes under the reader.
            set: { isOn in if isOn { model.setDiffScope(target) } }
        )) {
            Text(title ?? target.title)
            Text(subtitle)
        }
    }

    /// Shared, because a formatter is not cheap and this one is built for every row of the list.
    private static let age: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}
