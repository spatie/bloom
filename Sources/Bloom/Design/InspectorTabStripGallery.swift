import SwiftUI
import BloomCore

/// The inspector's tab strip in each state its segments can be in, on one page.
///
/// It exists because the strip is a control whose shape is the thing under review: whether the
/// Checks segment is there at all, and whether the two before it stay where they were when it
/// arrives or goes. One workspace shows one of those at a time, and no screen in the app puts a
/// branch with no pull request beside a branch with a green one.
///
/// The three rows are the three answers `InspectorTab.available` can give: no pull request, a pull
/// request GitHub has reported no runs for, and a pull request with runs. Only the last of them
/// draws a Checks segment.
///
/// Captured as a real window, light and dark:
/// `Bloom --snapshot-gallery <dir> --gallery inspector-tabs`. Deliberately not a `--snapshot`
/// scene: that path renders offscreen and paints a yellow placeholder over the segmented control
/// this page exists to show.
struct InspectorTabStripGallery: View {
    /// Held rather than made here: `WorkspaceModel` keeps its app unowned, so something with a
    /// longer life than a `body` has to own it.
    let app: AppModel

    /// The width the inspector column sits at by default, which is the width the strip has to keep
    /// its segmented form at.
    private static let column: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            row(
                "No pull request",
                "Nothing pushed, nothing to check. Two segments.",
                pullRequest: nil
            )
            row(
                "A pull request with no checks",
                "A repository with no workflows. GitHub reported no runs, so there is still nothing to show.",
                pullRequest: Self.pullRequest(checks: .none, summary: "No checks")
            )
            row(
                "A pull request with checks",
                "GitHub reported runs, so the segment is there, last in the strip.",
                pullRequest: Self.pullRequest(checks: .passing, summary: "12 checks passed")
            )
            row(
                "A pull request whose checks are failing",
                "The same strip. What the pane says is the pane's business.",
                pullRequest: Self.pullRequest(checks: .failing, summary: "1 required check failed")
            )
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(
        _ title: String, _ note: String, pullRequest: PullRequest?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
            Text(note)
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            InspectorToolbar(model: model(pullRequest: pullRequest))
                .frame(width: Self.column)
                .background(Palette.surface)
                .overlay(alignment: .bottom) { Hairline() }
        }
    }

    // MARK: - Fixtures

    private static func pullRequest(
        checks: PullRequest.Checks, summary: String
    ) -> PullRequest {
        PullRequest(
            number: 42,
            title: "Hide the checks tab when there is nothing to check",
            url: "https://github.com/spatie/bloom/pull/42",
            state: "OPEN",
            checks: checks,
            checksSummary: summary,
            branch: "fix/checks-tab-gate"
        )
    }

    private func model(pullRequest: PullRequest?) -> WorkspaceModel {
        let model = WorkspaceModel(
            workspace: Workspace(
                repoID: RepoID("r1"),
                name: "checks-tab",
                branch: "fix/checks-tab-gate",
                path: "/tmp/bloom-snapshot/checks-tab",
                baseBranch: "main"
            ),
            app: app
        )
        model.pullRequest = pullRequest
        // Five, because that is the count the strip puts in the Changes segment's own title and a
        // segment sized for "Changes" alone is not the segment the reader sees.
        model.changedFiles = [
            ChangedFile(path: "Sources/BloomCore/InspectorTab.swift", change: .added, additions: 63),
            ChangedFile(path: "Sources/Bloom/State/WorkspaceModel.swift", change: .modified, additions: 12, deletions: 6),
            ChangedFile(path: "Sources/Bloom/Views/Inspector/InspectorToolbar.swift", change: .modified, additions: 6, deletions: 2),
            ChangedFile(path: "Sources/Bloom/Design/InspectorTabStripGallery.swift", change: .added, additions: 104),
            ChangedFile(path: "Tests/BloomCoreTests/InspectorTabTests.swift", change: .added, additions: 98),
        ]
        return model
    }
}

extension Gallery {
    /// The registry entry for this page. See `Gallery`.
    static let inspectorTabs = Gallery(
        name: "inspector-tabs",
        title: "Inspector tabs",
        size: CGSize(width: 460, height: 470),
        needsFocus: false,
        view: { app in AnyView(InspectorTabStripGallery(app: app)) }
    )
}
