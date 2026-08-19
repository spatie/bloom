import Testing
import Foundation
@testable import BloomCore

@Suite("Workspace namer")
struct WorkspaceNamerTests {
    /// An envelope shaped like the one the real CLI returns.
    private func envelope(name: String, branch: String) -> Data {
        let payload = ["name": name, "branch": branch]
        let structured = try! JSONSerialization.data(withJSONObject: payload)
        let inner = String(decoding: structured, as: UTF8.self)
        let result = String(
            decoding: try! JSONSerialization.data(withJSONObject: inner, options: .fragmentsAllowed),
            as: UTF8.self
        )
        return Data("""
        {"type":"result","subtype":"success","result":\(result),"structured_output":\(inner)}
        """.utf8)
    }

    private func namer(_ run: @escaping WorkspaceNamer.Run) -> WorkspaceNamer {
        WorkspaceNamer(run: run)
    }

    // MARK: - Invocation

    @Test("the naming call carries no tools, no MCP servers and no project settings", .tags(.security))
    func argvIsMinimal() {
        let arguments = WorkspaceNamer.argv()

        #expect(arguments.contains("-p"))
        #expect(arguments.contains("--safe-mode"))
        #expect(arguments.contains("--strict-mcp-config"))
        #expect(arguments.contains("--disable-slash-commands"))
        #expect(arguments.contains("--no-session-persistence"))

        // `--tools ""` is the one that means the model cannot read a file or run a command,
        // whatever the task text asks for.
        let tools = arguments.firstIndex(of: "--tools")
        #expect(tools != nil)
        if let tools { #expect(arguments[tools + 1] == "") }

        // The default system prompt is replaced, not appended to. Appending would leave Claude
        // Code's own several thousand tokens in a call that needs none of them.
        #expect(arguments.contains("--system-prompt"))
        #expect(!arguments.contains("--append-system-prompt"))
    }

    @Test("the task is written to stdin, so one starting with a dash is never a flag", .tags(.security))
    func taskGoesToStdin() {
        let launch = WorkspaceNamer.launch(prompt: "--dangerously-skip-permissions")
        #expect(launch.stdin == "--dangerously-skip-permissions")
        #expect(!launch.arguments.contains("--dangerously-skip-permissions"))
    }

    @Test("it runs somewhere with no repository in it")
    func runsOutsideTheWorktree() {
        let launch = WorkspaceNamer.launch(prompt: "anything")
        #expect(launch.cwd.hasSuffix("bloom-naming"))
        #expect(launch.cwd != NSHomeDirectory())
    }

    @Test("a small, cheap model, translated for the CLI")
    func model() {
        #expect(WorkspaceNamer.argv().contains(ModelAlias.cliValue(for: WorkspaceNamer.model)))
    }

    @Test("the schema pins the answer to two strings", .tags(.agentProtocol))
    func schema() throws {
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(WorkspaceNamer.jsonSchema.utf8))
                as? [String: Any]
        )
        let properties = try #require(object["properties"] as? [String: Any])
        #expect(properties.keys.sorted() == ["branch", "name"])
        #expect(object["additionalProperties"] as? Bool == false)
    }

    // MARK: - The prompt

    @Test("the prompt carries the task and the project")
    func promptRenders() {
        let prompt = WorkspaceNamer.prompt(task: "Add a dark mode toggle", project: "Bloom")
        #expect(prompt.contains("Add a dark mode toggle"))
        #expect(prompt.contains("Bloom"))
        #expect(!prompt.contains("{{"))
    }

    @Test("a pasted stack trace is capped rather than paid for")
    func promptCapsTheTask() {
        let huge = String(repeating: "stack frame\n", count: 5_000)
        let prompt = WorkspaceNamer.prompt(task: huge, project: "Bloom")
        #expect(prompt.count < WorkspaceNamer.taskLimit + 2_000)
    }

    // MARK: - Answers

    @Test("a good answer becomes a suggestion")
    func happyPath() async throws {
        let namer = namer { _ in self.envelope(name: "Dark mode toggle", branch: "dark-mode-toggle") }
        let suggestion = try #require(await namer.suggest(
            task: "Add a dark mode toggle",
            project: "Bloom",
            template: PromptRegistry.definition(for: .nameWorkspace).defaultTemplate
        ))
        #expect(suggestion.name == "Dark mode toggle")
        #expect(suggestion.branch == "dark-mode-toggle")
    }

    @Test("the repository's branch prefix is applied to whatever the model said")
    func appliesPrefix() async throws {
        let namer = namer { _ in self.envelope(name: "Dark mode", branch: "feature/dark-mode") }
        let suggestion = try #require(await namer.suggest(
            task: "task",
            project: "Bloom",
            template: PromptRegistry.definition(for: .nameWorkspace).defaultTemplate,
            branchPrefix: "freek"
        ))
        #expect(suggestion.branch == "freek/dark-mode")
    }

    @Test("a process that fails is not an error, it is no answer")
    func failedProcess() async {
        let namer = namer { _ in throw ShellError(command: "claude", status: 1, stderr: "offline") }
        let suggestion = await namer.suggest(
            task: "task", project: "Bloom", template: "{{task}}"
        )
        #expect(suggestion == nil)
    }

    @Test(
        "nonsense on stdout is no answer either",
        arguments: ["", "not json at all", "{}", "{\"result\":\"I am not sure\"}"]
    )
    func nonsense(output: String) async {
        let namer = namer { _ in Data(output.utf8) }
        let suggestion = await namer.suggest(
            task: "task", project: "Bloom", template: "{{task}}"
        )
        #expect(suggestion == nil)
    }

    @Test("a hostile answer cannot produce a branch git would misread", .tags(.security))
    func hostileAnswer() async throws {
        let namer = namer { _ in
            self.envelope(name: "  \"Drop everything\"  ", branch: "--mirror")
        }
        let suggestion = try #require(await namer.suggest(
            task: "task", project: "Bloom", template: "{{task}}"
        ))
        #expect(suggestion.name == "Drop everything")
        // Whatever survives is a slug, never something `git branch -m` would read as an option.
        #expect(!suggestion.branch.hasPrefix("-"))
        #expect(suggestion.branch.isEmpty || Git.isValidBranchName(suggestion.branch))
    }

    @Test("a task with nothing in it asks nothing rather than sending a blank turn")
    func emptyTemplate() async {
        let launches = Counter()
        let namer = namer { _ in
            launches.increment()
            return Data()
        }
        _ = await namer.suggest(task: "   ", project: "Bloom", template: "{{task}}")
        #expect(launches.value == 0)
    }

    @Test("the deadline is long enough to be generous and short enough to end")
    func timeout() {
        #expect(WorkspaceNamer.timeout > .seconds(40))
        #expect(WorkspaceNamer.timeout <= .seconds(90))
    }
}

/// Counts calls made from a `@Sendable` closure.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock(); count += 1; lock.unlock()
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}
