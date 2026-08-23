import SwiftUI
import BloomCore

/// Renders `PermissionAskRowView` in its four states for the snapshot run, each between two
/// ordinary tool rows, because that is how the transcript actually draws it. A spacing change to
/// the card reads as fixed when the card is photographed on its own and wrong the moment it is
/// back in a list, so the picture has to include the neighbours the spacing is negotiated with.
///
/// One padding serves every state, which is why the settled ones are on the page too: a value
/// tuned to the resolved line alone can crowd the buttons, and one tuned to the buttons can strand
/// the line. The open panel is drawn at three command lengths for the same reason, because the
/// rhythm has to hold at all of them. `Snapshot.render` picks this up as the "permission" scene,
/// light and dark.
struct PermissionSnapshotGallery: View {
    /// Three lengths, because the panel's spacing has to hold at all of them. A one line command is
    /// where too much padding shows as a panel of empty ground; a wrapped one is where too little
    /// shows as a box crushed against its own border; and a very long one is the only way to see
    /// what the panel costs in height when nothing about the command is hidden, which is the
    /// deliberate choice made here.
    enum Length: String, CaseIterable {
        case short
        case moderate
        case long

        var command: String {
            switch self {
            case .short:
                "./vendor/bin/pest --parallel"
            case .moderate:
                "gh api repos/spatie/laravel-webhook-server/commits/"
                    + "$(gh pr view 168 --json headRefOid -q .headRefOid)/check-runs "
                    + "--jq '.check_runs[] | {name, conclusion}'"
            case .long:
                (1...12).map {
                    "git log --oneline --since='\($0) days ago' --author='freek' "
                        + "--pretty=format:'%h %s' -- Sources/BloomCore/File\($0).swift"
                }.joined(separator: " && ")
            }
        }
    }

    private func ask(_ length: Length) -> PermissionAsk {
        PermissionAsk(
            requestID: "req-\(length.rawValue)",
            toolName: "Bash",
            input: .object(["command": .string(length.command)]),
            reason: "This command requires approval",
            suggestions: [
                PermissionSuggestion(
                    type: "addRules",
                    behavior: "allow",
                    rules: [PermissionRule(toolName: "Bash", ruleContent: "./vendor/bin/pest --parallel")]
                ),
            ]
        )
    }

    private var workspace: Workspace {
        Workspace(
            repoID: RepoID("r1"), name: "laravel-mobile-pass", branch: "main",
            path: "/tmp/nowhere", baseBranch: "main"
        )
    }

    private func toolRow(_ id: String, name: String, file: String) -> some View {
        ToolRowView(
            use: AgentToolUse(
                id: id, name: name,
                input: .object(["file_path": .string(file)])
            ),
            workspace: workspace,
            result: nil,
            isError: false,
            refusal: nil,
            durationMS: 1200,
            isExpanded: false,
            onToggle: {}
        )
    }

    private func slice(
        _ title: String,
        length: Length = .short,
        decision: String?,
        note: String = ""
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(Typo.micro)
                .foregroundStyle(Palette.textTertiary)
                .padding(.bottom, 4)
            VStack(alignment: .leading, spacing: 0) {
                toolRow("t1-\(title)", name: "Read", file: "/tmp/app/tests/PassTest.php")
                PermissionAskRowView(
                    ask: ask(length),
                    decision: decision,
                    note: note,
                    projectName: "laravel-mobile-pass"
                )
                toolRow("t2-\(title)", name: "Read", file: "/tmp/app/src/Pass.php")
            }
            .padding(.horizontal, TranscriptLayout.inset)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            slice("One line", length: .short, decision: nil)
            slice("Wrapped", length: .moderate, decision: nil)
            slice("Long and wrapped", length: .long, decision: nil)
            slice("Always allowed", decision: "allow-project")
            slice("Denied", decision: "deny")
        }
        .padding(20)
        .background(Palette.windowBackground)
    }
}
