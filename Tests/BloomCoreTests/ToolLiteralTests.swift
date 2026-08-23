import Testing
@testable import BloomCore

@Suite("Tool literals")
struct ToolLiteralTests {
    // MARK: What a machine will run

    @Test("A shell command is a literal, whole")
    func bashCommand() {
        let command = "gh api repos/spatie/laravel-webhook-server/commits/"
            + "$(gh pr view 168 --json headRefOid -q .headRefOid)/check-runs "
            + "--jq '.check_runs[] | {name, conclusion}'"

        #expect(ToolLiteral.of(name: "Bash", input: .object(["command": .string(command)])) == command)
        #expect(ToolLiteral.isCode(name: "Bash", input: .object(["command": .string(command)])))
    }

    /// The whole point of the copy button: what is on the pasteboard is never the one line the row
    /// had room for.
    @Test("A multi line command keeps its newlines and its length")
    func bashKeepsWholeCommand() {
        let command = "cat <<'EOF' > notes.txt\nline one\nline two\nEOF"
        let literal = ToolLiteral.of(name: "Bash", input: .object(["command": .string(command)]))

        #expect(literal == command)
        #expect(literal?.contains("\n") == true)
    }

    @Test("A slash command is a literal")
    func slashCommand() {
        #expect(ToolLiteral.of(name: "SlashCommand", input: .object(["command": .string("/review-pr 168")]))
            == "/review-pr 168")
    }

    // MARK: Paths

    @Test("A declared file is a literal, and the whole path rather than the name")
    func declaredFiles() {
        let path = "/Users/freek/dev/code/bloom/Sources/BloomCore/ToolLiteral.swift"
        for tool in ["Read", "Write", "Edit", "MultiEdit"] {
            #expect(ToolLiteral.of(name: tool, input: .object(["file_path": .string(path)])) == path)
        }
    }

    /// `Read` takes either, and a notebook read carries only the second.
    @Test("Read falls back to the notebook path")
    func readNotebook() {
        #expect(ToolLiteral.of(name: "Read", input: .object(["notebook_path": .string("/tmp/a.ipynb")]))
            == "/tmp/a.ipynb")
        #expect(ToolLiteral.of(name: "NotebookEdit", input: .object(["notebook_path": .string("/tmp/a.ipynb")]))
            == "/tmp/a.ipynb")
    }

    /// A path with spaces in it is still a path: the tool's own contract said so, and nothing is
    /// guessed for a declared field.
    @Test("A declared file with spaces is believed")
    func declaredFileWithSpaces() {
        let path = "/Users/freek/CleanShot 2026-08-19 at 09.29.05@2x.png"
        #expect(ToolLiteral.of(name: "Read", input: .object(["file_path": .string(path)])) == path)
    }

    // MARK: Queries and handles

    @Test("A glob and a regular expression are literals")
    func patterns() {
        #expect(ToolLiteral.of(name: "Glob", input: .object(["pattern": .string("**/*.swift")]))
            == "**/*.swift")
        #expect(ToolLiteral.of(name: "Grep", input: .object(["pattern": .string("await Git\\.")]))
            == "await Git\\.")
    }

    @Test("A shell handle and an agent id are literals")
    func handles() {
        #expect(ToolLiteral.of(name: "BashOutput", input: .object(["bash_id": .string("bash_1")])) == "bash_1")
        #expect(ToolLiteral.of(name: "KillShell", input: .object(["shell_id": .string("bash_1")])) == "bash_1")
        #expect(ToolLiteral.of(name: "TaskOutput", input: .object(["agent_id": .string("agent_7")])) == "agent_7")
    }

    @Test("A tool search query is a literal")
    func toolSearchQuery() {
        #expect(ToolLiteral.of(name: "ToolSearch", input: .object(["query": .string("select:Read,Edit")]))
            == "select:Read,Edit")
    }

    @Test("A fetched address is a literal, whole rather than its host")
    func webFetch() {
        let url = "https://example.com/docs/a?b=c"
        #expect(ToolLiteral.of(name: "WebFetch", input: .object(["url": .string(url)])) == url)
    }

    // MARK: Prose stays prose

    /// The mistake in the other direction, and the one the welcome window had: English set in mono
    /// reads as data.
    @Test("A sentence a person would read is not a literal", arguments: [
        ("Task", "description", "Explore the transcript and report back"),
        ("Agent", "description", "Explore the transcript and report back"),
        ("WebSearch", "query", "how do I rebase onto a moved branch"),
        ("SendMessage", "prompt", "Please also check the dark theme"),
        ("AskUserQuestion", "question", "Which branch should this land on?"),
        ("ExitPlanMode", "plan", "First rename the type, then move the tests"),
        ("EnterPlanMode", "reason", "Planning before touching anything"),
        ("Skill", "args", "list errors for the beacon project"),
    ])
    func prose(tool: String, key: String, value: String) {
        #expect(ToolLiteral.of(name: tool, input: .object([key: .string(value)])) == nil)
        #expect(!ToolLiteral.isCode(name: tool, input: .object([key: .string(value)])))
    }

    @Test("A todo write carries no literal")
    func todos() {
        let input = JSONValue.object([
            "todos": .array([.object(["content": .string("Rename the type"), "status": .string("pending")])]),
        ])
        #expect(ToolLiteral.of(name: "TodoWrite", input: input) == nil)
    }

    @Test("An argument that is present but empty is the same as one that is missing")
    func emptyArguments() {
        #expect(ToolLiteral.of(name: "Bash", input: .object(["command": .string("")])) == nil)
        #expect(ToolLiteral.of(name: "Read", input: .object([:])) == nil)
    }

    // MARK: Tools nothing here knows

    @Test("An MCP tool naming a file plainly gets that file")
    func mcpFile() {
        let input = JSONValue.object(["path": .string("docs/PROTOCOL.md")])
        #expect(ToolLiteral.of(name: "mcp__figma__get_design_context", input: input) == "docs/PROTOCOL.md")
    }

    /// The guess leans the same way `FilePathGuess` does: when it is not sure, it says no, and the
    /// row stays proportional.
    @Test("An MCP tool whose path is not a path is prose")
    func mcpNotAFile() {
        let input = JSONValue.object(["path": .string("app/Beacon/**/*.php")])
        #expect(ToolLiteral.of(name: "mcp__whatever__do_thing", input: input) == nil)
    }

    @Test("An unknown tool follows the same rule as an MCP one")
    func unknownTool() {
        #expect(ToolLiteral.of(name: "Frobnicate", input: .object(["file": .string("a/b.txt")])) == "a/b.txt")
        #expect(ToolLiteral.of(name: "Frobnicate", input: .object(["note": .string("a sentence")])) == nil)
    }
}

@Suite("Permission ask subjects")
struct PermissionAskSubjectTests {
    private func ask(tool: String, input: JSONValue, summary: String = "", blockedPath: String? = nil) -> PermissionAsk {
        PermissionAsk(
            requestID: "r1",
            toolName: tool,
            input: input,
            summary: summary,
            blockedPath: blockedPath
        )
    }

    @Test("A command is the subject, and it is code")
    func command() {
        let subject = ask(tool: "Bash", input: .object(["command": .string("rm -rf build")]))
        #expect(subject.subject == "rm -rf build")
        #expect(subject.subjectIsCode)
    }

    /// The case the old spelling missed. A `Grep` ask fell through to the CLI's description, which
    /// is a sentence, and the panel drew it in the monospace block anyway.
    @Test("A pattern is the subject now, where it used to fall through to the description")
    func pattern() {
        let subject = ask(
            tool: "Grep",
            input: .object(["pattern": .string("await Shell\\.")]),
            summary: "Search the worktree"
        )
        #expect(subject.subject == "await Shell\\.")
        #expect(subject.subjectIsCode)
    }

    @Test("A description with no literal behind it is not code")
    func description() {
        let subject = ask(
            tool: "AskUserQuestion",
            input: .object(["question": .string("Which branch?")]),
            summary: "The agent would like to ask you something"
        )
        #expect(subject.subject == "The agent would like to ask you something")
        #expect(!subject.subjectIsCode)
    }

    @Test("A blocked path is the subject when the input carries no literal, and it is code")
    func blocked() {
        let subject = ask(
            tool: "Frobnicate",
            input: .object([:]),
            summary: "Outside the worktree",
            blockedPath: "/etc/hosts"
        )
        #expect(subject.subject == "/etc/hosts")
        #expect(subject.subjectIsCode)
    }
}
