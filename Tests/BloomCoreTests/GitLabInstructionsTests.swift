import Foundation
import Testing
@testable import BloomCore

@Suite("GitLab instructions", .scratchDirectory)
struct GitLabInstructionsTests {
    @Test("every GitLab text, as it stands")
    func texts() {
        expectCharacterised(GitLabInstructions.mergeRequestMarkdown, "gitlab-mr-instructions.md")
        expectCharacterised(GitLabInstructions.merge, "gitlab-merge-instructions.md")
        expectCharacterised(GitLabInstructions.conflictMarkdown, "gitlab-conflict-instructions.md")
        for definition in PromptRegistry.all {
            guard let template = GitLabInstructions.defaultTemplate(for: definition.id) else { continue }
            expectCharacterised(template, "gitlab-prompt-\(definition.id.rawValue).txt")
        }
    }

    @Test("nothing sent to a GitLab project's agent names gh or GitHub's words")
    func noGitHubWords() {
        let texts = [GitLabInstructions.mergeRequestMarkdown, GitLabInstructions.merge, GitLabInstructions.conflictMarkdown]
            + PromptRegistry.all.compactMap { GitLabInstructions.defaultTemplate(for: $0.id) }
        for text in texts {
            #expect(!text.contains("`gh "), "\(text.prefix(60))")
            #expect(!text.contains("GitHub"), "\(text.prefix(60))")
            #expect(!text.localizedCaseInsensitiveContains("pull request"), "\(text.prefix(60))")
        }
        #expect(GitLabInstructions.merge.contains("--auto-merge=false"))
        #expect(GitLabInstructions.mergeRequestMarkdown.contains("glab mr create --target-branch"))
    }

    @Test("a GitHub override never reaches a GitLab project, and GitHub's lookup is unchanged")
    func overrides() throws {
        let defaults = try #require(UserDefaults(suiteName: "gitlab-prompts-\(UUID().uuidString)"))
        let overrides = PromptOverrides(defaults: defaults)
        overrides.set("Run gh pr merge now.", for: .mergePullRequest)

        #expect(overrides.template(for: .mergePullRequest, forge: .gitHub) == "Run gh pr merge now.")
        #expect(overrides.template(for: .mergePullRequest, forge: .gitLab)
            == GitLabInstructions.defaultTemplate(for: .mergePullRequest))

        defaults.set("Merge it with glab.", forKey: PromptOverrides.key(for: .mergePullRequest, forge: .gitLab))
        #expect(PromptOverrides.key(for: .mergePullRequest, forge: .gitLab) == "prompts.gitLab.mergePullRequest")
        #expect(overrides.template(for: .mergePullRequest, forge: .gitLab) == "Merge it with glab.")
        #expect(overrides.template(for: .review, forge: .gitLab) == overrides.template(for: .review))
    }

    @Test("the merge turn names GitLab's flags and carries GitLab's steps", arguments: [
        (method: GitHub.MergeMethod.squash, flag: "`--squash`"),
        (method: .rebase, flag: "`glab mr rebase` first, then no method flag"),
        (method: .merge, flag: "no method flag, the project's own merge method"),
    ])
    func mergeTurn(method: GitHub.MergeMethod, flag: String) {
        let context = MergePromptContext(
            workspaceName: "w", number: 12, title: "t", branch: "feature", baseBranch: "main",
            method: method, forge: .gitLab
        )
        let template = GitLabInstructions.defaultTemplate(for: .mergePullRequest) ?? ""
        let rendered = context.render(template: template).text
        #expect(rendered.hasPrefix("Merge merge request !12 into main as a "))
        #expect(rendered.contains("(\(flag))"))
        let turn = ProjectInstructions.turn(rendered, for: .merge, adding: .nothing, forge: .gitLab)
        #expect(turn.contains(GitLabInstructions.merge))
        #expect(!turn.contains(MergeInstructions.canonical))
    }

    @Test("a GitHub merge turn is what it was")
    func gitHubMergeTurn() {
        let context = MergePromptContext(
            workspaceName: "w", number: 12, title: "t", branch: "feature", baseBranch: "main", method: .squash
        )
        #expect(context.values[PromptRegistry.MergePullRequest.methodFlag] == "--squash")
        let turn = ProjectInstructions.turn("x", for: .merge, adding: .nothing)
        #expect(turn == "x\n\n" + MergeInstructions.canonical)
    }

    private static let referenceCases: [(text: String, number: Int, repository: String?)] = [
        ("!42", 42, nil),
        ("https://gitlab.com/group/sub/app/-/merge_requests/42", 42, "group/sub/app"),
        ("https://git.example.com/team/app/-/merge_requests/7/diffs", 7, "team/app"),
        ("https://github.com/acme/app/pull/9", 9, "acme/app"),
        ("#5", 5, nil),
    ]

    @Test("merge request references", arguments: referenceCases)
    func references(text: String, number: Int, repository: String?) throws {
        let reference = try #require(WorkspaceCheckoutPlan.parseReference(text, forge: .gitLab))
        #expect(reference.number == number)
        #expect(reference.repository == repository)
    }

    @Test("a GitHub project reads !12 and merge request URLs as it always did: not at all")
    func gitHubIgnoresMergeRequests() {
        #expect(WorkspaceCheckoutPlan.parseReference("!12") == nil)
        #expect(WorkspaceCheckoutPlan.parseReference("https://gitlab.com/group/app/-/merge_requests/12") == nil)
    }

    @Test("a GitLab worktree gets its own instructions file, beside GitHub's")
    func ownScratchFile() async throws {
        let worktree = TestScratch.unique("gitlab-scratch")
        try FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)
        let path = await PullRequestInstructions.ensure(
            in: worktree, contents: GitLabInstructions.mergeRequestMarkdown,
            scratch: GitLabInstructions.mergeRequestScratchPath
        )
        #expect(path == GitLabInstructions.mergeRequestScratchPath)
        let written = try String(contentsOfFile: "\(worktree)/\(GitLabInstructions.mergeRequestScratchPath)", encoding: .utf8)
        #expect(written == GitLabInstructions.mergeRequestMarkdown)
    }
}
