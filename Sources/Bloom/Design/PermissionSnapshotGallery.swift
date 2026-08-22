import SwiftUI
import BloomCore

/// Renders `PermissionAskRowView` in its four states for the snapshot run, each between two
/// ordinary tool rows, because that is how the transcript actually draws it. A spacing change to
/// the card reads as fixed when the card is photographed on its own and wrong the moment it is
/// back in a list, so the picture has to include the neighbours the spacing is negotiated with.
///
/// One padding serves all four states, which is why all four are on the page: a value tuned to
/// the resolved line alone can crowd the buttons, and one tuned to the buttons can strand the
/// line. `Snapshot.render` picks this up as the "permission" scene, light and dark.
struct PermissionSnapshotGallery: View {
    private var ask: PermissionAsk {
        PermissionAsk(
            requestID: "req-1",
            toolName: "Bash",
            input: .object(["command": .string("./vendor/bin/pest --parallel")]),
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

    private func slice(_ title: String, decision: String?, note: String = "") -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(Typo.micro)
                .foregroundStyle(Palette.textTertiary)
                .padding(.bottom, 4)
            VStack(alignment: .leading, spacing: 0) {
                toolRow("t1-\(title)", name: "Read", file: "/tmp/app/tests/PassTest.php")
                PermissionAskRowView(
                    ask: ask,
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
            slice("Unresolved", decision: nil)
            slice("Always allowed", decision: "allow-project")
            slice("Allowed once", decision: "allow-once")
            slice("Denied", decision: "deny")
        }
        .padding(20)
        .background(Palette.windowBackground)
    }
}
