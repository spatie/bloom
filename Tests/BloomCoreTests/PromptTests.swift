import Testing
import Foundation
@testable import BloomCore

/// Bloom asks the coding agent to open pull requests rather than shelling out to `gh` itself, so
/// the wording of that request is now a piece of behaviour with its own failure modes: a token that
/// never gets filled, a value the workspace could not supply, and an override that survives a trip
/// through storage without its line breaks being mangled.
@Suite("Prompt templates")
struct PromptTemplateTests {
    @Test("every declared variable is substituted")
    func substitutesDeclaredVariables() {
        let render = PromptTemplate.render(
            "Branch {{branch}} onto {{base_branch}}.",
            values: ["branch": "feature/x", "base_branch": "main"]
        )

        #expect(render.text == "Branch feature/x onto main.")
        #expect(render.unknown.isEmpty)
        #expect(render.missing.isEmpty)
    }

    @Test("a variable used twice is substituted twice")
    func substitutesRepeatedVariables() {
        let render = PromptTemplate.render("{{a}}-{{a}}", values: ["a": "x"])

        #expect(render.text == "x-x")
    }

    @Test("an unknown variable is left alone and reported")
    func leavesUnknownVariablesAlone() {
        let render = PromptTemplate.render(
            "Push {{branch}} then {{brnach}}.",
            values: ["branch": "main"]
        )

        // Kept verbatim on purpose: a typo that reaches the agent as `{{brnach}}` is obvious in the
        // transcript, where silently dropping it would look like the prompt simply said less.
        #expect(render.text == "Push main then {{brnach}}.")
        #expect(render.unknown == ["brnach"])
        #expect(render.missing.isEmpty)
    }

    @Test("the same unknown variable is only reported once")
    func reportsEachUnknownOnce() {
        let render = PromptTemplate.render("{{x}} {{x}} {{y}}", values: [:])

        #expect(render.unknown == ["x", "y"])
    }

    @Test("a supplied but empty value renders as nothing and is reported as missing")
    func reportsMissingValues() {
        let render = PromptTemplate.render(
            "Task: {{task}}!",
            values: ["task": ""]
        )

        #expect(render.text == "Task: !")
        #expect(render.missing == ["task"])
        #expect(render.unknown.isEmpty)
    }

    @Test("whitespace inside the braces is ignored")
    func trimsVariableNames() {
        let render = PromptTemplate.render("{{  branch  }}", values: ["branch": "main"])

        #expect(render.text == "main")
    }

    @Test("braces that do not hold an identifier are prose, not a variable")
    func leavesNonVariableBracesUntouched() {
        let template = "Handlebars looks like {{ this is not a name }} and JSON like {{\"a\": 1}}."
        let render = PromptTemplate.render(template, values: ["a": "x"])

        #expect(render.text == template)
        #expect(render.unknown.isEmpty)
    }

    @Test("an unterminated opening brace is left as written")
    func leavesUnterminatedBraces() {
        let render = PromptTemplate.render("tail {{branch", values: ["branch": "main"])

        #expect(render.text == "tail {{branch")
    }

    @Test("a template with no variables comes back unchanged")
    func passesPlainTextThrough() {
        let render = PromptTemplate.render("Open a pull request.", values: ["branch": "main"])

        #expect(render.text == "Open a pull request.")
    }

    @Test("variable names are listed in the order they appear")
    func listsVariableNames() {
        #expect(PromptTemplate.variableNames(in: "{{b}} {{a}} {{b}}") == ["b", "a"])
    }

    @Test("multi-line templates keep their line breaks")
    func preservesLineBreaks() {
        let render = PromptTemplate.render("one\n\ntwo {{x}}\nthree", values: ["x": "X"])

        #expect(render.text == "one\n\ntwo X\nthree")
    }
}

@Suite("Prompt registry")
struct PromptRegistryTests {
    @Test("every prompt id has a definition")
    func coversEveryID() {
        for id in PromptID.allCases {
            #expect(PromptRegistry.definition(for: id).id == id)
        }
        #expect(PromptRegistry.all.count == PromptID.allCases.count)
    }

    @Test("a built-in prompt only uses variables it declares")
    func declaresEveryVariableItUses() throws {
        for definition in PromptRegistry.all {
            let declared = Set(definition.variables.map(\.name))
            let used = Set(PromptTemplate.variableNames(in: definition.defaultTemplate))
            #expect(used.subtracting(declared).isEmpty, "\(definition.id) uses undeclared variables")
        }
    }

    @Test("the create pull request default is one sentence naming the target branch")
    func createPullRequestDefaultRendersFully() throws {
        let definition = PromptRegistry.definition(for: .createPullRequest)
        let context = PullRequestPromptContext(
            workspaceName: "Bloom",
            branch: "freek/prompts",
            baseBranch: "main",
            task: "Move PR creation onto the agent",
            changes: "- Sources/BloomCore/PromptTemplate.swift (added, +90/-0)"
        )

        let render = context.render(template: definition.defaultTemplate)

        #expect(render.unknown.isEmpty)
        #expect(render.missing.isEmpty)
        #expect(render.text.contains("main"))
        #expect(!render.text.contains(PromptTemplate.open))
        // The how lives in the attached file, not in the message. A turn that carried the whole
        // procedure inline is the thing this replaced.
        #expect(!render.text.contains("gh pr create"))
        #expect(render.text.count < 120)
    }

    @Test("a template that does ask for the facts gets prose when the workspace has none")
    func fallsBackForEmptyFacts() {
        let context = PullRequestPromptContext(
            workspaceName: "Bloom",
            branch: "wip",
            baseBranch: "main",
            task: "",
            changes: ""
        )

        // Not the built-in one, which asks for neither. The fallbacks exist for an override that
        // does, and a heading followed by nothing is what they prevent.
        let render = context.render(template: "{{task}}\n{{changes}}")

        #expect(render.missing.isEmpty)
        #expect(render.text.contains(PullRequestPromptContext.noTask))
        #expect(render.text.contains(PullRequestPromptContext.noChanges))
    }
}

@Suite("Pull request instructions", .scratchDirectory)
struct PullRequestInstructionsTests {
    @Test("the file is written on demand, inside the worktree, and answers with a relative path")
    func writesOnDemand() throws {
        let worktree = TestScratch.unique("worktree")
        try FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)

        let path = PullRequestInstructions.ensure(in: worktree)

        #expect(path == PullRequestInstructions.path)
        let full = (worktree as NSString).appendingPathComponent(PullRequestInstructions.path)
        let written = try String(contentsOfFile: full, encoding: .utf8)
        #expect(written == PullRequestInstructions.defaultMarkdown)
    }

    /// Once it exists it belongs to the project. Rewriting it would silently undo somebody's
    /// edit every time the button was pressed.
    @Test("a file that is already there is never rewritten")
    func neverOverwrites() throws {
        let worktree = TestScratch.unique("worktree")
        let full = (worktree as NSString).appendingPathComponent(PullRequestInstructions.path)
        try FileManager.default.createDirectory(
            atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try "Ours, not yours.".write(toFile: full, atomically: true, encoding: .utf8)

        #expect(PullRequestInstructions.ensure(in: worktree) == PullRequestInstructions.path)
        #expect(try String(contentsOfFile: full, encoding: .utf8) == "Ours, not yours.")
    }

    @Test("a worktree that cannot be written to answers nil rather than throwing")
    func failsSoftly() {
        #expect(PullRequestInstructions.ensure(in: "/dev/null/nowhere") == nil)
    }

    /// The instructions are shared by every workspace in the repository, so a branch name in them
    /// would be wrong for all but one.
    @Test("the default instructions name no branch")
    func namesNoBranch() {
        #expect(!PullRequestInstructions.defaultMarkdown.contains("--base main"))
        #expect(PullRequestInstructions.defaultMarkdown.contains("<target branch>"))
    }

    @Test("the turn the agent receives is the sentence plus a normal attachment trailer")
    func composesAsAnAttachment() {
        let text = AttachmentTrailer.compose(
            text: "Create a pull request for this workspace against main.",
            paths: [PullRequestInstructions.path]
        )

        let (body, paths) = AttachmentTrailer.split(text)
        #expect(body == "Create a pull request for this workspace against main.")
        #expect(paths == [PullRequestInstructions.path])
    }
}

@Suite("Pull request prompt context")
struct PullRequestPromptContextTests {
    @Test("changed files are summarised one per line with their counts")
    func summarisesChangedFiles() {
        let summary = PullRequestPromptContext.changeSummary([
            ChangedFile(path: "a.swift", change: .modified, additions: 3, deletions: 1),
            ChangedFile(path: "new/b.swift", change: .added, additions: 12, deletions: 0),
            ChangedFile(path: "c.png", change: .added, isBinary: true),
            ChangedFile(path: "new.txt", oldPath: "old.txt", change: .renamed),
        ])

        #expect(summary == """
        - a.swift (modified, +3/-1)
        - new/b.swift (added, +12/-0)
        - c.png (added, binary)
        - old.txt -> new.txt (renamed, +0/-0)
        """)
    }

    @Test("a long file list is capped and the remainder counted")
    func capsLongFileLists() {
        let files = (0..<5).map { ChangedFile(path: "f\($0).swift", change: .modified) }

        let summary = PullRequestPromptContext.changeSummary(files, limit: 2)

        #expect(summary.hasSuffix("- ...and 3 more files"))
        #expect(summary.split(separator: "\n").count == 3)
    }

    @Test("one file over the cap is counted in the singular")
    func countsOneRemainingFileInSingular() {
        let files = (0..<3).map { ChangedFile(path: "f\($0).swift", change: .modified) }

        #expect(PullRequestPromptContext.changeSummary(files, limit: 2).hasSuffix("- ...and 1 more file"))
    }

    @Test("no changes summarises to nothing, so the context can substitute its own wording")
    func summarisesNoChangesAsEmpty() {
        #expect(PullRequestPromptContext.changeSummary([]).isEmpty)
    }

    @Test("the opening prompt is read back out of a stored user turn")
    func readsUserTurnText() throws {
        let line = try AgentRunner.encodeTurn("Rebuild the inspector")

        #expect(UserTurnPayload.text(from: Data(line.utf8)) == "Rebuild the inspector")
    }

    @Test("a payload that is not a user turn reads as nothing")
    func ignoresOtherPayloads() {
        #expect(UserTurnPayload.text(from: Data(#"{"type":"result"}"#.utf8)) == nil)
        #expect(UserTurnPayload.text(from: Data("not json".utf8)) == nil)
    }
}

@Suite("Prompt overrides")
struct PromptOverridesTests {
    /// Its own defaults suite per test, so a stored override cannot leak into the next one or into
    /// the machine's real preferences.
    private func makeDefaults() throws -> (UserDefaults, String) {
        let name = "bloom.prompts.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (defaults, name)
    }

    @Test("with nothing stored, the built-in prompt is used")
    func fallsBackToBuiltIn() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let overrides = PromptOverrides(defaults: defaults)

        #expect(overrides.stored(for: .createPullRequest) == nil)
        #expect(overrides.isCustomised(for: .createPullRequest) == false)
        #expect(overrides.template(for: .createPullRequest)
            == PromptRegistry.definition(for: .createPullRequest).defaultTemplate)
    }

    @Test("an empty override falls back to the built-in rather than sending a blank turn")
    func emptyOverrideFallsBack() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let overrides = PromptOverrides(defaults: defaults)
        let builtIn = PromptRegistry.definition(for: .createPullRequest).defaultTemplate

        for blank in ["", "   ", "\n\n", " \n\t "] {
            overrides.set(blank, for: .createPullRequest)

            // Still customised: the user emptied it deliberately and the settings form has to show
            // that. What falls back is only what gets sent.
            #expect(overrides.isCustomised(for: .createPullRequest))
            #expect(overrides.template(for: .createPullRequest) == builtIn)
        }
    }

    @Test("a multi-line override survives a round trip through storage")
    func roundTripsMultiLineTemplates() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let overrides = PromptOverrides(defaults: defaults)

        let template = """
        Open a PR for {{branch}}.

        \tIndented, with a tab.
        Trailing spaces:
        Unicode: é ✓ 🎻

        Last line with no newline after it.
        """

        overrides.set(template, for: .createPullRequest)

        // A fresh reader against the same suite, because the question is what storage kept rather
        // than what one instance happened to hold.
        let reread = PromptOverrides(defaults: defaults)
        #expect(reread.stored(for: .createPullRequest) == template)
        #expect(reread.template(for: .createPullRequest) == template)

        let render = PromptTemplate.render(
            reread.template(for: .createPullRequest),
            values: ["branch": "wip"]
        )
        #expect(render.text.contains("Open a PR for wip."))
        #expect(render.text.contains("\tIndented, with a tab."))
        #expect(render.text.hasSuffix("Last line with no newline after it."))
    }

    @Test("clearing an override goes back to never customised")
    func clearingRemovesTheOverride() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let overrides = PromptOverrides(defaults: defaults)

        overrides.set("mine", for: .createPullRequest)
        overrides.set(nil, for: .createPullRequest)

        #expect(overrides.stored(for: .createPullRequest) == nil)
        #expect(overrides.isCustomised(for: .createPullRequest) == false)
    }

    @Test("the storage key is namespaced by prompt id")
    func namespacesStorageKeys() {
        #expect(PromptOverrides.key(for: .createPullRequest) == "prompts.createPullRequest")
    }
}
