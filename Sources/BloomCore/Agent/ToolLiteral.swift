import Foundation

/// The literal string a tool call is about: a command, a path, a pattern, an id.
///
/// One type in the core answering two questions the transcript used to take inside a view, where
/// nothing could test either of them.
///
/// **Which text is set in the monospace face.** The rule the window already states is that mono is
/// for what a machine said or what a machine will run. A collapsed tool row put its argument in the
/// proportional face while the permission panel four points below it put the same command in mono,
/// so the two disagreed about the same string. A shell command is read character by character, and
/// `-rf` next to `-r f` is the difference the proportional face hides. A row whose argument is not
/// a literal (the sentence a subagent was given, a search phrase somebody would say out loud, a
/// count of todos) stays proportional, because English set in mono reads as data.
///
/// **What a copy button puts on the pasteboard.** A row shows a basename, or a command collapsed to
/// one line and cut at the pane's edge. What gets copied is the whole thing, which is the only
/// version worth pasting into a terminal.
///
/// The field each tool keeps its literal in is written down once, here, rather than once in the
/// presenter and again in the permission ask. Both read it from this, so neither can drift from the
/// other the way they already had.
public enum ToolLiteral {
    /// The whole literal a call was given, or nil when the tool's argument is prose.
    ///
    /// Nil is the honest answer for far more tools than it might look. `Task` carries a sentence,
    /// `WebSearch` carries a phrase, `TodoWrite` carries a list of English, and an MCP server Bloom
    /// has never heard of carries whatever it likes. Only a value the tool's own contract says is
    /// literal, or one `FilePathGuess` will vouch for, comes back non-nil.
    public static func of(name: String, input: JSONValue) -> String? {
        if name.hasPrefix("mcp__") { return namedFile(in: input) }

        switch name {
        // A file the tool's contract declares. Believed rather than guessed at, exactly as
        // `ToolPresenter` believes it: `Read` already said the argument was a file.
        case "Read":
            return text(input, "file_path") ?? text(input, "notebook_path")
        case "Write", "Edit", "MultiEdit":
            return text(input, "file_path")
        case "NotebookEdit":
            return text(input, "notebook_path")

        // What a machine will run.
        case "Bash":
            return text(input, "command")
        case "SlashCommand":
            return text(input, "command")

        // A handle a machine minted. Nobody reads `bash_1` as a word, and a run of them only lines
        // up in a column if they are set in a face whose digits do.
        case "BashOutput":
            return text(input, "bash_id") ?? text(input, "shell_id")
        case "KillShell", "KillBash":
            return text(input, "shell_id") ?? text(input, "bash_id")
        case "TaskOutput", "TaskStop":
            return text(input, "task_id") ?? text(input, "agent_id")

        // A query in a syntax rather than a question in a language: a glob, a regular expression,
        // and `ToolSearch`'s `select:Read,Edit` form.
        case "Glob", "Grep":
            return text(input, "pattern")
        case "ToolSearch":
            return text(input, "query")

        // An address, which is literal in the way a path is: every character of a host counts.
        case "WebFetch":
            return text(input, "url")

        default:
            // A tool nothing here knows. It gets the same treatment an MCP one does: a file if it
            // names one plainly enough for `FilePathGuess` to be sure, and prose otherwise. A
            // guess that leant the other way would set a sentence in mono, which is the mistake
            // this exists to stop rather than one it may make.
            return namedFile(in: input)
        }
    }

    /// Whether a tool row's argument should be set as code.
    ///
    /// Deliberately the same question as "is there something here worth copying", because it is:
    /// both are asking whether the string is a literal or a sentence.
    public static func isCode(name: String, input: JSONValue) -> Bool {
        of(name: name, input: input) != nil
    }

    // MARK: Codex

    /// The same question of a Codex thread item.
    ///
    /// Codex has no tool names, so it cannot go through the switch above, but a row drawn from a
    /// Codex chat sits in the same list as a row drawn from a Claude one and a command has to look
    /// like a command in both. Here the payloads are typed, so there is nothing to guess.
    ///
    /// The command comes back unwrapped, which is what the row shows and therefore what a copy
    /// button has to put on the pasteboard: pasting `/bin/zsh -lc 'git status'` back into a shell
    /// runs a shell inside a shell.
    public static func of(codex item: CodexItem) -> String? {
        switch item {
        case .commandExecution(let run):
            let command = unwrapShell(run.command)
            return command.isEmpty ? nil : command
        // One file names itself; several are counted, and "3 files" is a sentence.
        case .fileChange(let change):
            guard change.changes.count == 1 else { return nil }
            let path = change.changes[0].path
            return path.isEmpty ? nil : path
        case .webSearch(let search):
            // An opened page is an address. A query, in either of the other two actions, is
            // whatever the model felt like typing.
            guard search.action == "openPage", let url = search.url, !url.isEmpty else { return nil }
            return url
        case .subAgentActivity(let activity):
            return activity.agentPath.isEmpty ? nil : activity.agentPath
        // Prose, a count, an error sentence, or a payload nothing here has a reading for.
        case .userMessage, .agentMessage, .reasoning, .plan, .mcpToolCall, .contextCompaction, .other:
            return nil
        }
    }

    /// `/bin/zsh -lc 'ls -la'` becomes `ls -la`. Codex wraps everything in the login shell, so the
    /// wrapper is the same on every line and says nothing.
    ///
    /// Only when the whole tail is one quoted argument, because anything else is a command that
    /// genuinely contains a shell invocation and rewriting it would be showing a line that was
    /// never run.
    ///
    /// Here rather than beside the Codex presenter, where it was, because it is now two callers:
    /// the row's own text and the string a copy button hands over. Those two must not be able to
    /// differ, and a pure string function in a view was one nothing could test either.
    public static func unwrapShell(_ command: String) -> String {
        let markers = [" -lc ", " -c "]
        for marker in markers {
            guard let range = command.range(of: marker) else { continue }
            let tail = command[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard tail.count >= 2, let first = tail.first else { continue }
            guard first == "'" || first == "\"", tail.last == first else { continue }
            let inner = String(tail.dropFirst().dropLast())
            // A quote inside means the tail was more than one argument, and the split is a guess.
            guard !inner.contains(first) else { continue }
            return inner
        }
        return command
    }

    /// The file an unknown tool is about, if it names one plainly enough to be sure.
    ///
    /// Keys in a fixed order rather than the input's own, so a tool carrying two of them always
    /// answers with the same one. Every value still has to pass the guess: an MCP server is free to
    /// put a glob in something called `path`, and this is exactly the case where nothing but the
    /// string is known.
    private static func namedFile(in input: JSONValue) -> String? {
        for key in ["file_path", "notebook_path", "filename", "path", "file"] {
            guard let value = input[key]?.stringValue, !value.isEmpty else { continue }
            guard FilePathGuess.looksLikeAFile(value) else { continue }
            return value
        }
        return nil
    }

    /// A non-empty string at `key`, or nil. An argument present but empty is nothing to draw and
    /// nothing to copy, so it is the same answer as an argument that is not there at all.
    private static func text(_ input: JSONValue, _ key: String) -> String? {
        guard let value = input[key]?.stringValue, !value.isEmpty else { return nil }
        return value
    }
}
