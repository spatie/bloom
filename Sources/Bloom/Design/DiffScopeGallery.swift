import SwiftUI
import BloomCore

/// The Changes tab in each of the three things it can be measuring from, with the count the strip
/// shows and the band that says why it is that number.
///
/// It exists because the count and the reason for it are two controls a pane apart, and the whole
/// point of the band is that they agree. One workspace shows one scope at a time.
///
/// The strips are real `InspectorToolbar`s at the inspector's default width, which is the other
/// thing this page is for: the row has a segmented control that falls back to a pop-up button the
/// moment its segments stop fitting, and the scope control is a fourth thing in it.
///
/// `Snapshot.scheduleGalleryCapture` picks this up as `--gallery diff-scope`.
struct DiffScopeGallery: View {
    let app: AppModel

    /// What the split view gives this column when nothing has been dragged.
    private static let column = Metrics.inspectorWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            case_("All changes", "Everything since the branch left main. The band is not there.") {
                strip(.all, files: 69)
            }

            case_("Uncommitted changes", "Sixty-nine becomes seven, and the band says what the seven were counted from.") {
                strip(.uncommitted, files: 7)
                DiffScopeBand(scope: .uncommitted, fileCount: 7) {}
            }

            case_("Since a commit", "Measured from a commit on this branch. The band names it by sha.") {
                strip(.since(Self.commit), files: 12)
                DiffScopeBand(scope: .since(Self.commit), fileCount: 12) {}
            }

            case_("With comments the scope leaves out", "Nothing is at risk, so the band says so rather than warning.") {
                DiffScopeBand(
                    scope: .uncommitted,
                    fileCount: 7,
                    note: DiffScope.uncommitted.strandedNote(Self.comments, among: [])
                ) {}
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func case_(
        _ title: String, _ note: String, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Typo.label).foregroundStyle(Palette.textSecondary)
            Text(note)
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                content()
            }
            .frame(width: Self.column)
            .background(Palette.surface)
            .overlay(alignment: .bottom) { Hairline() }
        }
    }

    private func strip(_ scope: DiffScope, files: Int) -> some View {
        InspectorToolbar(model: model(scope, files: files))
    }

    // MARK: - Fixtures

    private static let commit = BranchCommit(
        sha: "9c4b1a70f3e2d5c8b6a49f0e1d2c3b4a5f6e7d80",
        subject: "Teach the parser about renames",
        author: "Freek",
        date: Date(timeIntervalSinceNow: -7_200)
    )

    private static let comments: [ReviewComment] = ["Sources/Old.swift", "Sources/Older.swift"].map {
        ReviewComment(
            workspaceID: WorkspaceID("w1"),
            filePath: $0,
            side: .new,
            anchor: ReviewCommentAnchor(line: 12, text: "let x = 1", before: [], after: []),
            body: "This retries for ever."
        )
    }

    private func model(_ scope: DiffScope, files: Int) -> WorkspaceModel {
        let model = WorkspaceModel(
            workspace: Workspace(
                repoID: RepoID("r1"),
                name: "diff-scope",
                branch: "feat/diff-scope",
                path: "/tmp/bloom-snapshot/diff-scope",
                baseBranch: "main"
            ),
            app: app
        )
        model.pullRequest = PullRequest(
            number: 42, title: "Scope the diff", url: "", state: "OPEN",
            checks: .passing, checksSummary: "12 checks passed", branch: "feat/diff-scope"
        )
        model.changedFiles = (0..<files).map {
            ChangedFile(path: "Sources/File\($0).swift", change: .modified, additions: 4, deletions: 1)
        }
        model.setDiffScope(scope)
        return model
    }
}

extension Gallery {
    /// The registry entry for this page. See `Gallery`.
    static let diffScope = Gallery(
        name: "diff-scope",
        title: "Diff scope",
        size: CGSize(width: 460, height: 700),
        needsFocus: false,
        view: { app in AnyView(DiffScopeGallery(app: app)) }
    )
}
