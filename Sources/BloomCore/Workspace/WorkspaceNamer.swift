import Foundation

/// Everything needed to ask a model for a name, as a value, so the invocation can be asserted on
/// without a process ever existing. The same shape, and the same reason, as `AgentLaunch`.
public struct WorkspaceNamerLaunch: Sendable, Hashable {
    public let executable: String
    public let arguments: [String]
    /// The rendered prompt. Written to the child's stdin rather than passed as an argument, so a
    /// task that begins with a dash can never be read as a flag.
    public let stdin: String
    public let cwd: String

    public init(executable: String, arguments: [String], stdin: String, cwd: String) {
        self.executable = executable
        self.arguments = arguments
        self.stdin = stdin
        self.cwd = cwd
    }
}

/// Asks a model for a workspace name and a branch, and is allowed to fail.
///
/// ## Why a separate `claude -p` and not the workspace's own agent
///
/// The workspace's agent is the wrong tool three times over. It carries Claude Code's full system
/// prompt, the repository's `CLAUDE.md`, its skills and its MCP servers, which is thousands of
/// tokens of context that say nothing about what to call a task. Its answer would land in the
/// user's transcript, in the middle of the turn they actually asked for. And it is busy: by the
/// time it could answer, it is already working, and a naming question would either queue behind
/// the real turn or interrupt it.
///
/// ## Why the CLI and not the API
///
/// Because of the credentials. Most people running Claude Code are signed in with a subscription,
/// not an API key, and the token that represents that sign-in lives in `~/.claude.json`. Bloom
/// does not read it, does not hold it and does not send it anywhere: the CLI authenticates, the
/// same way it does for every other agent turn this app runs. An HTTP client inside Bloom would
/// mean Bloom handling a live credential, and would not work at all for the majority of users who
/// have no API key to hand it.
///
/// ## What the invocation is trimmed down to
///
/// `--system-prompt` replaces Claude Code's own, which is the single largest saving. `--tools ""`
/// leaves the model nothing to call, so it cannot read a file or run a command whatever the task
/// text says. `--safe-mode`, `--strict-mcp-config` and `--disable-slash-commands` between them
/// mean no `CLAUDE.md`, no plugins, no hooks and no MCP servers. `--no-session-persistence` keeps
/// it out of the user's `/resume` list. The working directory is a scratch directory rather than
/// the worktree, so there is nothing there to discover in the first place. Measured against the
/// real CLI: about a thousand input tokens and well under a cent a call.
public struct WorkspaceNamer: Sendable {
    /// Runs a launch and hands back its stdout. Injected so tests drive the whole path without a
    /// network, an account or a bill.
    public typealias Run = @Sendable (WorkspaceNamerLaunch) async throws -> Data

    /// The same binary the rest of the app runs. Resolved through `Shell.which`, so a Finder
    /// launch finds it in the same places `AgentRunner` does.
    public static let executable = "claude"

    /// Fixed, not a setting.
    ///
    /// Naming a task is two short strings from one paragraph. Haiku does it as well as anything
    /// larger and it is several times faster. Tying this to the model picker would mean somebody
    /// on Opus paying twenty times as much, and waiting several times as long, for the same four
    /// words.
    public static let model = "haiku"

    /// Replaces the CLI's own system prompt outright. Short on purpose: everything about what to
    /// answer is in the user-editable prompt, and this only has to establish that the structured
    /// output is the whole of the reply.
    public static let systemPrompt = """
    You name coding tasks for a list of workspaces. Answer at once, through the structured \
    output, with no commentary before or after it.
    """

    /// Forces the shape of the answer, so parsing is not a guess about prose.
    public static let jsonSchema = """
    {"type":"object","properties":{"name":{"type":"string"},"branch":{"type":"string"}},\
    "required":["name","branch"],"additionalProperties":false}
    """

    /// How long a name is worth waiting for.
    ///
    /// Generous, because nothing is blocked on it: the workspace exists, its setup has run and
    /// its agent is already working. What the deadline is really there for is the call that never
    /// returns at all, so that the placeholder resolves to the mechanical name rather than
    /// standing forever.
    ///
    /// Measured against the real CLI, the call takes eight to seventeen seconds most of the time
    /// and has been seen to take thirty-eight. Almost all of that is the model's own extended
    /// thinking, which the CLI gives no way to switch off; the process itself starts in under two
    /// seconds. A deadline under half a minute would throw away perfectly good answers on a slow
    /// morning, and there is nothing to gain by it.
    public static let timeout = Duration.seconds(60)

    /// How much of the task the model is shown.
    ///
    /// A pasted stack trace or a design document can run to tens of kilobytes, and none of it
    /// past the first few paragraphs changes what the work should be called. Everything after
    /// this is dropped, which caps both the cost and the time.
    public static let taskLimit = 4_000

    private let run: Run

    public init(run: @escaping Run = WorkspaceNamer.shell) {
        self.run = run
    }

    /// The production runner.
    public static let shell: Run = { launch in
        let result = try await Shell.run(
            launch.executable,
            launch.arguments,
            cwd: launch.cwd,
            stdin: launch.stdin,
            timeout: timeout
        )
        guard result.ok else {
            throw ShellError(
                command: launch.executable,
                status: result.status,
                // The CLI's stderr is its own diagnostics, never a credential, and it is the only
                // thing that says why a naming call failed.
                stderr: result.stderr.isEmpty ? result.stdout : result.stderr
            )
        }
        return Data(result.stdout.utf8)
    }

    /// Whether there is anything to ask. Checked before a placeholder is ever handed out, so a
    /// machine with no `claude` on it gets the mechanical name straight away and never sees a
    /// codename that would not resolve.
    public static var isAvailable: Bool {
        Shell.which(executable) != nil
    }

    public static func argv(model: String = WorkspaceNamer.model) -> [String] {
        [
            "-p",
            "--model", ModelAlias.cliValue(for: model),
            // Measurably fewer thinking tokens, which is where nearly all the latency is. Naming
            // a task is not a problem that rewards deliberation.
            "--effort", "low",
            "--output-format", "json",
            "--json-schema", jsonSchema,
            "--system-prompt", systemPrompt,
            // Empty string means "no tools at all". The naming call has no business reading
            // anything, and this is what guarantees it cannot.
            "--tools", "",
            "--disable-slash-commands",
            "--strict-mcp-config",
            "--no-session-persistence",
            "--safe-mode",
        ]
    }

    /// A directory with nothing in it, so the CLI has no project to discover.
    ///
    /// Not the worktree and not the home directory: both carry a `CLAUDE.md` and a git repository,
    /// and while `--safe-mode` already refuses to read them, the cheapest way to be sure a naming
    /// call cannot see a user's code is to run it where there is none.
    public static var scratchDirectory: String {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("bloom-naming")
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    public static func launch(prompt: String, model: String = WorkspaceNamer.model) -> WorkspaceNamerLaunch {
        WorkspaceNamerLaunch(
            executable: executable,
            arguments: argv(model: model),
            stdin: prompt,
            cwd: scratchDirectory
        )
    }

    /// The rendered prompt for one workspace.
    public static func prompt(
        task: String,
        project: String,
        template: String = PromptRegistry.definition(for: .nameWorkspace).defaultTemplate
    ) -> String {
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = trimmed.count > taskLimit ? String(trimmed.prefix(taskLimit)) : trimmed

        return PromptTemplate.render(template, values: [
            PromptRegistry.NameWorkspace.task: capped,
            PromptRegistry.NameWorkspace.project: project,
        ]).text
    }

    /// Asks, and answers nil for every way this can go wrong.
    ///
    /// There is no error path out of here on purpose. A workspace that exists and is being worked
    /// in must not be interrupted because a naming call could not reach the network, and there is
    /// nothing the user could usefully do about it if it were reported. The caller falls back to
    /// the mechanical name, which is what they would have had anyway.
    public func suggest(
        task: String,
        project: String,
        template: String,
        branchPrefix: String? = nil
    ) async -> WorkspaceNameSuggestion? {
        let rendered = Self.prompt(task: task, project: project, template: template)
        guard !rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        guard let output = try? await run(Self.launch(prompt: rendered)) else { return nil }
        guard let decoded = WorkspaceNaming.decode(cliOutput: output) else { return nil }

        return WorkspaceNaming.suggestion(
            name: decoded.name,
            branch: decoded.branch,
            branchPrefix: branchPrefix
        )
    }
}
