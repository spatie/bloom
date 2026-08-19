import SwiftUI
import BloomCore

/// Turns a tool name plus its arbitrary input object into something readable.
///
/// Every built-in Claude Code tool gets a bespoke case. The parameter names are the ones the CLI
/// actually sends (see PROTOCOL.md and fixtures/session-basic.jsonl), and anything unrecognised
/// still lands on a sensible line rather than nothing, because new tools ship constantly.
enum ToolPresenter {
    static func present(_ use: AgentToolUse) -> ToolPresentation {
        present(name: use.name, input: use.input)
    }

    static func present(name: String, input: JSONValue) -> ToolPresentation {
        if name.hasPrefix("mcp__") { return mcp(name: name, input: input) }

        switch name {
        case "Read": return read(input)
        case "Write": return write(input)
        case "Edit": return edit(input)
        case "MultiEdit": return multiEdit(input)
        case "NotebookEdit": return notebookEdit(input)
        case "Bash": return bash(input)
        case "BashOutput": return bashOutput(input)
        case "KillShell", "KillBash": return killShell(input)
        case "Glob": return glob(input)
        case "Grep": return grep(input)
        case "Task", "Agent": return task(input)
        case "TaskOutput": return taskOutput(input)
        case "TaskStop": return taskStop(input)
        case "SendMessage": return sendMessage(input)
        case "TodoWrite": return todos(input)
        case "WebFetch": return webFetch(input)
        case "WebSearch": return webSearch(input)
        case "SlashCommand": return slashCommand(input)
        case "Skill": return skill(input)
        case "AskUserQuestion": return askUserQuestion(input)
        case "ExitPlanMode": return exitPlanMode(input)
        case "EnterPlanMode": return enterPlanMode(input)
        case "ToolSearch": return toolSearch(input)
        case "ListAgents": return ToolPresentation(
            glyph: "person.2.badge.gearshape",
            label: "List agents",
            detail: "",
            tint: Palette.textSecondary
        )
        default: return fallback(name: name, input: input)
        }
    }

    // MARK: Files

    private static func read(_ input: JSONValue) -> ToolPresentation {
        let path = input["file_path"]?.stringValue ?? input["notebook_path"]?.stringValue ?? ""
        let file = basename(path)

        var label = "Read"
        if let limit = input["limit"]?.intValue, limit > 0 { label = "Read \(limit) lines" }

        var chips: [ToolChip] = []
        if let named = declaredFile(path) { chips.append(named) }
        if let offset = input["offset"]?.intValue, offset > 0 { chips.append(.code("from \(offset)")) }
        if let pages = input["pages"]?.stringValue { chips.append(.code("p\(pages)")) }

        return ToolPresentation(glyph: "doc.text", label: label, detail: file, tint: Palette.accent, chips: chips)
    }

    private static func write(_ input: JSONValue) -> ToolPresentation {
        let path = input["file_path"]?.stringValue ?? ""
        let file = basename(path)
        let lines = lineCount(input["content"]?.stringValue ?? "")

        var chips: [ToolChip] = []
        if let named = declaredFile(path) { chips.append(named) }
        if lines > 0 { chips.append(.code("\(lines) lines")) }

        return ToolPresentation(
            glyph: "square.and.pencil",
            label: "Write",
            detail: file,
            tint: Palette.positive,
            chips: chips
        )
    }

    private static func edit(_ input: JSONValue) -> ToolPresentation {
        let path = input["file_path"]?.stringValue ?? ""
        let file = basename(path)

        var chips: [ToolChip] = []
        if let named = declaredFile(path) { chips.append(named) }
        if input["replace_all"]?.boolValue == true { chips.append(.code("all")) }

        return ToolPresentation(
            glyph: "pencil.line",
            label: "Edit",
            detail: file,
            tint: Palette.positive,
            chips: chips
        )
    }

    private static func multiEdit(_ input: JSONValue) -> ToolPresentation {
        let path = input["file_path"]?.stringValue ?? ""
        let file = basename(path)
        let count = input["edits"]?.arrayValue?.count ?? 0

        var chips: [ToolChip] = []
        if let named = declaredFile(path) { chips.append(named) }
        if count > 0 { chips.append(.code("\(count) edits")) }

        return ToolPresentation(
            glyph: "pencil.line",
            label: "Edit",
            detail: file,
            tint: Palette.positive,
            chips: chips
        )
    }

    private static func notebookEdit(_ input: JSONValue) -> ToolPresentation {
        let path = input["notebook_path"]?.stringValue ?? ""
        let file = basename(path)

        var chips: [ToolChip] = []
        if let named = declaredFile(path) { chips.append(named) }
        if let mode = input["edit_mode"]?.stringValue { chips.append(.code(mode)) }

        return ToolPresentation(
            glyph: "book.closed",
            label: "Notebook",
            detail: file,
            tint: Palette.positive,
            chips: chips
        )
    }

    // MARK: Shell

    private static func bash(_ input: JSONValue) -> ToolPresentation {
        let command = oneLine(input["command"]?.stringValue ?? "")
        // Claude writes a short description of every command it runs, and that reads far better
        // as the label than the word "Bash" repeated forty times down the transcript.
        let label = input["description"]?.stringValue.map { oneLine($0) } ?? "Bash"

        // Never a file chip, whatever the command happens to contain. A command is code, it is
        // already drawn as the detail, and the argument most likely to look like a path here is
        // the one word of a command that is not one.
        var chips: [ToolChip] = []
        if input["run_in_background"]?.boolValue == true { chips.append(.code("background")) }

        return ToolPresentation(
            glyph: "terminal",
            label: label.isEmpty ? "Bash" : label,
            detail: command,
            tint: Palette.textSecondary,
            chips: chips
        )
    }

    private static func bashOutput(_ input: JSONValue) -> ToolPresentation {
        let shell = input["bash_id"]?.stringValue ?? input["shell_id"]?.stringValue ?? ""

        var chips: [ToolChip] = []
        if let filter = input["filter"]?.stringValue, !filter.isEmpty { chips.append(.code(filter)) }

        return ToolPresentation(
            glyph: "terminal.fill",
            label: "Shell output",
            detail: shell,
            tint: Palette.textSecondary,
            chips: chips
        )
    }

    private static func killShell(_ input: JSONValue) -> ToolPresentation {
        let shell = input["shell_id"]?.stringValue ?? input["bash_id"]?.stringValue ?? ""
        return ToolPresentation(
            glyph: "terminal",
            label: "Kill shell",
            detail: shell,
            tint: Palette.negative
        )
    }

    // MARK: Search

    private static func glob(_ input: JSONValue) -> ToolPresentation {
        // The pattern is the detail and stays a pattern; `path` is the directory the search was
        // rooted at, which is a folder rather than a file and so keeps its plain chip.
        var chips: [ToolChip] = []
        if let path = input["path"]?.stringValue, !path.isEmpty { chips.append(.code(basename(path))) }

        return ToolPresentation(
            glyph: "magnifyingglass",
            label: "Find files",
            detail: input["pattern"]?.stringValue ?? "",
            tint: Palette.accent,
            chips: chips
        )
    }

    private static func grep(_ input: JSONValue) -> ToolPresentation {
        var chips: [ToolChip] = []
        if let glob = input["glob"]?.stringValue, !glob.isEmpty { chips.append(.code(glob)) }
        // The one declared field in the whole presenter that is genuinely either: `path` is a file
        // or a directory depending on how the search was written. So it is the one that goes
        // through the guess rather than being believed.
        if let path = input["path"]?.stringValue, !path.isEmpty { chips.append(guessedFile(path)) }

        return ToolPresentation(
            glyph: "text.magnifyingglass",
            label: "Search",
            detail: input["pattern"]?.stringValue ?? "",
            tint: Palette.accent,
            chips: chips
        )
    }

    private static func toolSearch(_ input: JSONValue) -> ToolPresentation {
        ToolPresentation(
            glyph: "wrench.adjustable",
            label: "Find tools",
            detail: oneLine(input["query"]?.stringValue ?? ""),
            tint: Palette.textSecondary
        )
    }

    // MARK: Subagents

    private static func task(_ input: JSONValue) -> ToolPresentation {
        let type = input["subagent_type"]?.stringValue ?? "agent"
        var chips: [ToolChip] = []
        if let model = input["model"]?.stringValue { chips.append(.code(model)) }
        if let isolation = input["isolation"]?.stringValue { chips.append(.code(isolation)) }

        return ToolPresentation(
            glyph: "person.2",
            label: "Agent: \(type)",
            detail: oneLine(input["description"]?.stringValue ?? ""),
            tint: Palette.warning,
            chips: chips
        )
    }

    private static func taskOutput(_ input: JSONValue) -> ToolPresentation {
        ToolPresentation(
            glyph: "person.2.wave.2",
            label: "Agent output",
            detail: input["task_id"]?.stringValue ?? input["agent_id"]?.stringValue ?? "",
            tint: Palette.warning
        )
    }

    private static func taskStop(_ input: JSONValue) -> ToolPresentation {
        ToolPresentation(
            glyph: "person.2.slash",
            label: "Stop agent",
            detail: input["task_id"]?.stringValue ?? input["agent_id"]?.stringValue ?? "",
            tint: Palette.negative
        )
    }

    private static func sendMessage(_ input: JSONValue) -> ToolPresentation {
        ToolPresentation(
            glyph: "paperplane",
            label: "Message agent",
            detail: oneLine(input["prompt"]?.stringValue ?? input["message"]?.stringValue ?? ""),
            tint: Palette.warning,
            chips: (input["agent_id"]?.stringValue).map { [ToolChip.code($0)] } ?? []
        )
    }

    // MARK: Planning and process

    private static func todos(_ input: JSONValue) -> ToolPresentation {
        let items = input["todos"]?.arrayValue ?? []
        let done = items.count { $0["status"]?.stringValue == "completed" }
        let active = items.first { $0["status"]?.stringValue == "in_progress" }
        let running = active?["activeForm"]?.stringValue ?? active?["content"]?.stringValue

        var chips: [ToolChip] = []
        if let running, !running.isEmpty { chips.append(.code(oneLine(running, limit: 60))) }

        return ToolPresentation(
            glyph: "checklist",
            label: "Todos",
            detail: "\(items.count) items, \(done) done",
            tint: Palette.textSecondary,
            chips: chips
        )
    }

    private static func exitPlanMode(_ input: JSONValue) -> ToolPresentation {
        ToolPresentation(
            glyph: "checkmark.seal",
            label: "Plan ready",
            detail: firstLine(input["plan"]?.stringValue ?? ""),
            tint: Palette.accent
        )
    }

    private static func enterPlanMode(_ input: JSONValue) -> ToolPresentation {
        ToolPresentation(
            glyph: "list.bullet.clipboard",
            label: "Plan mode",
            detail: oneLine(input["reason"]?.stringValue ?? "Planning before touching anything"),
            tint: Palette.accent
        )
    }

    private static func askUserQuestion(_ input: JSONValue) -> ToolPresentation {
        let questions = input["questions"]?.arrayValue ?? []
        let first = questions.first
        let text = first?["question"]?.stringValue ?? input["question"]?.stringValue ?? ""

        var chips: [ToolChip] = []
        if questions.count > 1 { chips.append(.code("\(questions.count) questions")) }

        return ToolPresentation(
            glyph: "questionmark.bubble",
            label: "Question",
            detail: oneLine(text),
            tint: Palette.warning,
            chips: chips
        )
    }

    private static func slashCommand(_ input: JSONValue) -> ToolPresentation {
        let command = input["command"]?.stringValue ?? ""
        return ToolPresentation(
            glyph: "command",
            label: "Command",
            detail: oneLine(command),
            tint: Palette.textSecondary
        )
    }

    private static func skill(_ input: JSONValue) -> ToolPresentation {
        let name = input["skill"]?.stringValue ?? input["name"]?.stringValue ?? ""
        return ToolPresentation(
            glyph: "wand.and.stars",
            label: "Skill",
            detail: oneLine(input["args"]?.stringValue ?? ""),
            tint: Palette.accent,
            chips: name.isEmpty ? [] : [.code(name)]
        )
    }

    // MARK: Web

    private static func webFetch(_ input: JSONValue) -> ToolPresentation {
        let url = input["url"]?.stringValue ?? ""
        return ToolPresentation(
            glyph: "globe",
            label: "Fetch",
            detail: host(url),
            tint: Palette.accent
        )
    }

    private static func webSearch(_ input: JSONValue) -> ToolPresentation {
        ToolPresentation(
            glyph: "magnifyingglass.circle",
            label: "Web search",
            detail: oneLine(input["query"]?.stringValue ?? ""),
            tint: Palette.accent
        )
    }

    // MARK: Unknown shapes

    /// `mcp__linear__create_issue` reads as "linear: create issue". The double underscore is the
    /// separator the CLI uses, and single underscores inside the tool name are word breaks.
    private static func mcp(name: String, input: JSONValue) -> ToolPresentation {
        let parts = name.dropFirst("mcp__".count).components(separatedBy: "__")
        let server = parts.first ?? name
        let tool = parts.dropFirst().joined(separator: " ").replacing("_", with: " ")
        let label = tool.isEmpty ? server : "\(server): \(tool)"

        // An MCP server can name a file as plainly as a built in tool does, and one that does gets
        // the same chip. Nothing here knows the server's schema, so the value has to survive the
        // guess before it is believed.
        if let path = namedFile(in: input) {
            return ToolPresentation(
                glyph: "puzzlepiece.extension",
                label: label,
                detail: basename(path),
                tint: Palette.textSecondary,
                chips: [.file(path: path)]
            )
        }

        return ToolPresentation(
            glyph: "puzzlepiece.extension",
            label: label,
            detail: firstScalar(input),
            tint: Palette.textSecondary
        )
    }

    /// A tool Bloom has never heard of still has to read as a sentence, so the name goes in the
    /// label and the most likely looking argument goes in the detail. Never the JSON itself.
    private static func fallback(name: String, input: JSONValue) -> ToolPresentation {
        if let path = namedFile(in: input) {
            return ToolPresentation(
                glyph: "wrench.and.screwdriver",
                label: name,
                detail: basename(path),
                tint: Palette.textSecondary,
                chips: [.file(path: path)]
            )
        }

        return ToolPresentation(
            glyph: "wrench.and.screwdriver",
            label: name,
            detail: firstScalar(input),
            tint: Palette.textSecondary
        )
    }

    // MARK: Which arguments are files

    /// A field the tool's own contract says is a file: `Read`, `Write`, `Edit`, `MultiEdit` and
    /// `NotebookEdit` all take one and take nothing else in that parameter.
    ///
    /// Believed, rather than guessed at. That is what lets `FilePathGuess` be as strict as it is:
    /// a screenshot called `CleanShot 2026-08-19 at 09.29.05@2x.png` has four spaces in it and no
    /// string rule could accept it without also accepting `npm run dev`, but `Read` already said it
    /// was a file, so nothing has to be inferred. The only thing checked is that the value is
    /// shaped like a path at all, which catches an empty argument and a CLI that has changed under
    /// us rather than a wrong guess.
    private static func declaredFile(_ path: String) -> ToolChip? {
        guard !path.isEmpty else { return nil }
        guard FilePathGuess.isWellFormed(path) else { return .code(oneLine(path, limit: 60)) }
        return .file(path: path)
    }

    /// A field that could be a file and could be something else, which in the built in tools is
    /// `Grep`'s `path` and nothing else. Guessed at, and the guess says no unless it is sure.
    private static func guessedFile(_ path: String) -> ToolChip {
        FilePathGuess.looksLikeAFile(path) ? .file(path: path) : .code(basename(path))
    }

    /// The file an unknown tool is about, if it names one plainly enough to be sure.
    ///
    /// Keys in a fixed order rather than the input's own, so a tool that carries two of them always
    /// shows the same one, and only keys whose name says "file". Every value still has to pass the
    /// guess: an MCP server is free to put a glob in something called `path`, and this is exactly
    /// the case where nothing but the string is known.
    private static func namedFile(in input: JSONValue) -> String? {
        for key in ["file_path", "notebook_path", "filename", "path", "file"] {
            guard let value = input[key]?.stringValue else { continue }
            guard FilePathGuess.looksLikeAFile(value) else { continue }
            return value
        }
        return nil
    }

    // MARK: Text helpers

    static func basename(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let last = trimmed.split(separator: "/").last else { return trimmed }
        return String(last)
    }

    /// Collapses every run of whitespace, so a heredoc or a multi line command still occupies
    /// exactly one row. The hard cap keeps a pathological command from costing real layout time.
    static func oneLine(_ text: String, limit: Int = 300) -> String {
        var out = ""
        out.reserveCapacity(min(text.count, limit + 1))
        var pendingSpace = false

        for character in text {
            if character.isWhitespace {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace {
                out.append(" ")
                pendingSpace = false
            }
            out.append(character)
            if out.count >= limit { return out + "\u{2026}" }
        }
        return out
    }

    static func firstLine(_ text: String) -> String {
        oneLine(text.prefix(while: { $0 != "\n" }).description)
    }

    static func host(_ url: String) -> String {
        guard let parsed = URL(string: url) else { return oneLine(url) }
        return parsed.host() ?? oneLine(url)
    }

    /// `Git.countLines`, not a second rule.
    ///
    /// This counted a trailing newline as starting an empty last line, so a file written with one,
    /// which is nearly every file, was reported one line longer here than in the inspector beside
    /// it. The turn footer's rollup is built from this, so a turn that wrote three files read
    /// three lines heavier than the changed file list showed.
    static func lineCount(_ text: String) -> Int {
        Git.countLines(text)
    }

    /// The first scalar in the input, keys in sorted order so the same tool always shows the same
    /// field rather than whatever the dictionary felt like today.
    static func firstScalar(_ input: JSONValue) -> String {
        guard let object = input.objectValue else { return scalar(input) ?? "" }
        for key in object.keys.sorted() {
            if let value = object[key], let text = scalar(value) { return text }
        }
        return ""
    }

    private static func scalar(_ value: JSONValue) -> String? {
        switch value {
        case .string(let text): return text.isEmpty ? nil : oneLine(text)
        case .integer(let number): return String(number)
        case .number(let number):
            // Not `Int(number)`: a tool argument can legitimately hold a value past Int.max, and
            // that conversion traps rather than failing.
            guard number == number.rounded(), let exact = Int(exactly: number) else {
                return String(number)
            }
            return String(exact)
        case .bool(let flag): return flag ? "true" : "false"
        case .null, .array, .object: return nil
        }
    }
}
