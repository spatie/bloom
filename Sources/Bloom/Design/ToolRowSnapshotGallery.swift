import SwiftUI
import BloomCore

/// Renders a run of collapsed tool rows for the snapshot run, so the face the detail is set in can
/// be looked at rather than argued about.
///
/// The rows are a deliberate mix of the two answers `ToolLiteral` gives. A command, a path, a glob
/// and a regular expression are literals and are set as code; the sentence a subagent was handed,
/// a web search phrase and a count of todos are not, and stay in the proportional face. A page
/// showing only commands would look right whatever rule produced it, and the mistake this guards
/// against is the other one: English set in mono, which reads as data.
///
/// The command is the real one from the report that prompted the change, at its real length, so the
/// picture answers the question that actually matters. Monospace is the wider face, so the same row
/// shows fewer characters than it did, and a page that photographed a short command would hide
/// exactly that.
///
/// `Snapshot.render` picks this up as the "tool-rows" scene, light and dark.
struct ToolRowSnapshotGallery: View {
    /// 154 characters, wrapped in nothing. This is the line from the screenshot.
    private static let longCommand = "gh api repos/spatie/laravel-webhook-server/commits/"
        + "$(gh pr view 168 --json headRefOid -q .headRefOid)/check-runs "
        + "--jq '.check_runs[] | {name, conclusion}'"

    /// A real brief, at a real length. Set in mono this ran to about two thirds of the measure
    /// and broke where nothing broke.
    private static let brief = """
        Read the transcript's row views and work out where the decision is taken that a tool's \
        detail is a literal rather than a sentence. Report the file and the line, and say whether \
        the same rule reaches the block inside an expanded row.

        Do not change anything. This is a question, not a task.
        """

    /// A real worktree path, at a real length, because the rows below are about what happens to
    /// one. See `CommandDisplay`.
    private static let worktree = "/Users/freek/bloom/workspaces/there-there/freekmurze-hibiki-sea"

    private var workspace: Workspace {
        Workspace(
            repoID: RepoID("r1"), name: "laravel-webhook-server", branch: "main",
            path: Self.worktree, baseBranch: "main"
        )
    }

    private func row(
        _ id: String,
        _ name: String,
        _ input: [String: JSONValue],
        isExpanded: Bool = false
    ) -> some View {
        let use = AgentToolUse(id: id, name: name, input: .object(input))
        return ToolRowView(
            use: use,
            presentation: TranscriptPresenter.present(use, worktree: workspace.path),
            workspace: workspace,
            result: nil,
            isError: false,
            refusal: nil,
            durationMS: 1_200,
            isExpanded: isExpanded,
            onToggle: {}
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            group("Literals, set as code") {
                row("r1", "Bash", [
                    "description": .string("Check check-runs and PR conclusions"),
                    "command": .string(Self.longCommand),
                ])
                row("r2", "Bash", [
                    "description": .string("Run the suite"),
                    "command": .string("./vendor/bin/pest --parallel --filter=WebhookCallTest"),
                ])
                row("r3", "Read", ["file_path": .string("/tmp/app/src/WebhookCall.php")])
                row("r4", "Glob", ["pattern": .string("app/Beacon/**/*.php")])
                row("r5", "Grep", ["pattern": .string("await Git\\.|await Shell\\.")])
                row("r6", "WebFetch", ["url": .string("https://spatie.be/docs/laravel-webhook-server")])
            }

            group("Prose, left in the reading face") {
                row("p1", "Task", [
                    "subagent_type": .string("Explore"),
                    "description": .string("Find where the transcript decides which rows are code"),
                ])
                row("p2", "WebSearch", ["query": .string("how do I rebase onto a branch that moved")])
                row("p3", "TodoWrite", ["todos": .array([
                    .object(["content": .string("Set the command in mono"), "status": .string("completed")]),
                    .object(["content": .string("Add the copy button"), "status": .string("in_progress")]),
                ])])
                row("p4", "AskUserQuestion", [
                    "question": .string("Should the copy button sit on the row or on the panel?"),
                ])
            }

            // The four answers `CommandDisplay` gives, in the order a reader meets them. The
            // first two are the point of the change and the third is what it must not break: a
            // command that ran outside the workspace keeps its path, in the warning ink.
            group("Where a command ran") {
                row("c1", "Bash", [
                    "description": .string("List admin tests"),
                    "command": .string("cd \(Self.worktree)\nls tests/Http/Admin"),
                ])
                row("c2", "Bash", [
                    "description": .string("Run the api package tests"),
                    "command": .string("cd \(Self.worktree)/packages/api && npm test -- --runInBand"),
                ])
                row("c3", "Bash", [
                    "description": .string("Check the other worktree"),
                    "command": .string("cd /Users/freek/bloom/workspaces/bloom/main && git log --oneline -5"),
                ])
                row("c4", "Bash", [
                    "description": .string("Show the current diff"),
                    "command": .string("git diff --stat"),
                ])
            }

            group("Opened, with the block a copy button sits on") {
                row("e1", "Bash", [
                    "description": .string("Check check-runs and PR conclusions"),
                    "command": .string(Self.longCommand),
                ], isExpanded: true)

                // The drawer, which is where the rule the page above states was being broken: the
                // row header set this tool's detail in the reading face and then the block under
                // it set the whole brief in mono. Photographed open, because collapsed it looks
                // right either way.
                row("e2", "Task", [
                    "subagent_type": .string("Explore"),
                    "description": .string("Find where the transcript decides which rows are code"),
                    "prompt": .string(Self.brief),
                ], isExpanded: true)
            }
        }
        .frame(width: 760, alignment: .leading)
        .padding(20)
        .background(Palette.windowBackground)
    }

    private func group(
        _ title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(Typo.micro)
                .foregroundStyle(Palette.textTertiary)
                .padding(.bottom, 4)
            content()
        }
    }
}
