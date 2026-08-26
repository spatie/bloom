import Foundation

/// Turns a tool name plus its arbitrary input object into something readable.
///
/// In the core, where the decisions can be asked about. Every built-in tool has a bespoke case
/// deciding which input becomes the label and how each one truncates, and all of it sat in a view:
/// this file had already conceded `ToolLiteral` to the core "so the presenter cannot answer
/// differently from the permission panel below it", which is the same argument for the rest of it.
/// The one thing that kept it here was `ToolPresentation.tint` being a `Color`. It is a `ToolTint`
/// now, and the colour is one `switch` in the app.
///
/// Every built-in Claude Code tool gets a bespoke case. The parameter names are the ones the CLI
/// actually sends (see docs/PROTOCOL.md and Tests/fixtures/session-basic.jsonl), and anything unrecognised
/// still lands on a sensible line rather than nothing, because new tools ship constantly.
public enum ToolPresenter {
    public static func present(_ use: AgentToolUse, worktree: String = "") -> ToolPresentation {
        present(name: use.name, input: use.input, worktree: worktree)
    }

    /// The row, and then the one thing about it that is decided in the core: what the argument
    /// literally is. `ToolLiteral` is asked once here rather than per case, so the presenter cannot
    /// answer differently from the permission panel below it, which reads the same type.
    ///
    /// `worktree` is the workspace this call ran in, and the only thing it decides is which
    /// leading `cd` a shell row may hide. Empty hides nothing, which is what every caller with no
    /// workspace to hand wants.
    public static func present(name: String, input: JSONValue, worktree: String = "") -> ToolPresentation {
        var presentation = shape(name: name, input: input, worktree: worktree)
        presentation.literal = ToolLiteral.of(name: name, input: input)
        return presentation
    }

    private static func shape(name: String, input: JSONValue, worktree: String) -> ToolPresentation {
        if name.hasPrefix("mcp__") { return mcp(name: name, input: input) }

        switch name {
        case "Read": return read(input)
        case "Write": return write(input)
        case "Edit": return edit(input)
        case "MultiEdit": return multiEdit(input)
        case "NotebookEdit": return notebookEdit(input)
        case "Bash": return bash(input, worktree: worktree)
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
            tint: .neutral
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

        return ToolPresentation(glyph: "doc.text", label: label, detail: file, tint: .accent, chips: chips)
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
            tint: .positive,
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
            tint: .positive,
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
            tint: .positive,
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
            tint: .positive,
            chips: chips
        )
    }

    // MARK: Shell

    private static func bash(_ input: JSONValue, worktree: String) -> ToolPresentation {
        // Before the one line collapse, not after: a newline is one of the separators a `cd`
        // prefix ends with, and collapsing it first leaves a space nothing can tell from an
        // argument. See `CommandDisplay`.
        let display = CommandDisplay.of(input["command"]?.stringValue ?? "", worktree: worktree)
        let command = oneLine(display.command)
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
            // The mark for a command that left the workspace goes on the glyph, at the left edge
            // where a reader's eye runs down, rather than on a hue in the middle of the line. Every
            // `.elsewhere` gets it, the ones whose destination could not be read included: "this
            // went somewhere and I cannot tell where" is as worth seeing as a resolved path.
            tint: display.leftTheWorkspace ? .warning : .neutral,
            chips: chips,
            detailLead: display.lead
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
            tint: .neutral,
            chips: chips
        )
    }

    private static func killShell(_ input: JSONValue) -> ToolPresentation {
        let shell = input["shell_id"]?.stringValue ?? input["bash_id"]?.stringValue ?? ""
        return ToolPresentation(
            glyph: "terminal",
            label: "Kill shell",
            detail: shell,
            tint: .negative
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
            tint: .accent,
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
            tint: .accent,
            chips: chips
        )
    }

    private static func toolSearch(_ input: JSONValue) -> ToolPresentation {
        ToolPresentation(
            glyph: "wrench.adjustable",
            label: "Find tools",
            detail: oneLine(input["query"]?.stringValue ?? ""),
            tint: .neutral
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
            tint: .warning,
            chips: chips
        )
    }

    private static func taskOutput(_ input: JSONValue) -> ToolPresentation {
        ToolPresentation(
            glyph: "person.2.wave.2",
            label: "Agent output",
            detail: input["task_id"]?.stringValue ?? input["agent_id"]?.stringValue ?? "",
            tint: .warning
        )
    }

    private static func taskStop(_ input: JSONValue) -> ToolPresentation {
        ToolPresentation(
            glyph: "person.2.slash",
            label: "Stop agent",
            detail: input["task_id"]?.stringValue ?? input["agent_id"]?.stringValue ?? "",
            tint: .negative
        )
    }

    private static func sendMessage(_ input: JSONValue) -> ToolPresentation {
        ToolPresentation(
            glyph: "paperplane",
            label: "Message agent",
            detail: oneLine(input["prompt"]?.stringValue ?? input["message"]?.stringValue ?? ""),
            tint: .warning,
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
            tint: .neutral,
            chips: chips
        )
    }

    private static func exitPlanMode(_ input: JSONValue) -> ToolPresentation {
        ToolPresentation(
            glyph: "checkmark.seal",
            label: "Plan ready",
            detail: firstLine(input["plan"]?.stringValue ?? ""),
            tint: .accent
        )
    }

    private static func enterPlanMode(_ input: JSONValue) -> ToolPresentation {
        ToolPresentation(
            glyph: "list.bullet.clipboard",
            label: "Plan mode",
            detail: oneLine(input["reason"]?.stringValue ?? "Planning before touching anything"),
            tint: .accent
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
            tint: .warning,
            chips: chips
        )
    }

    private static func slashCommand(_ input: JSONValue) -> ToolPresentation {
        let command = input["command"]?.stringValue ?? ""
        return ToolPresentation(
            glyph: "command",
            label: "Command",
            detail: oneLine(command),
            tint: .neutral
        )
    }

    private static func skill(_ input: JSONValue) -> ToolPresentation {
        let name = input["skill"]?.stringValue ?? input["name"]?.stringValue ?? ""
        return ToolPresentation(
            glyph: "wand.and.stars",
            label: "Skill",
            detail: oneLine(input["args"]?.stringValue ?? ""),
            tint: .accent,
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
            tint: .accent
        )
    }

    private static func webSearch(_ input: JSONValue) -> ToolPresentation {
        ToolPresentation(
            glyph: "magnifyingglass.circle",
            label: "Web search",
            detail: oneLine(input["query"]?.stringValue ?? ""),
            tint: .accent
        )
    }

    // MARK: Unknown shapes

    /// `mcp__linear__create_issue` reads as "linear: create issue". The double underscore is the
    /// separator the CLI uses, and single underscores inside the tool name are word breaks.
    private static func mcp(name: String, input: JSONValue) -> ToolPresentation {
        let parts = name.dropFirst("mcp__".count).components(separatedBy: "__")
        let server = parts.first ?? name
        let tool = parts.dropFirst().joined(separator: " ").replacing("_", with: " ")
        // Bloom's own bridge, said as Bloom.
        //
        // The wire name is `bloom-workspace-bridge` and it has to stay that, which is not a
        // convention: `BridgeRegistration.serverName` records the measurement behind it, that a
        // Codex `-c` override deep-merges a colliding entry leaf by leaf rather than replacing
        // it, so a server the owner had called `bloom` produced Bloom's binary running under the
        // owner's arguments and reported itself healthy. The defence is a name nobody would type.
        //
        // None of which the reader should have to look at. A row reading
        // "bloom-workspace-bridge: pane open" names the transport where every other row names the
        // thing that happened, and the puzzle piece says "some extension" about the app the
        // reader is already in. Both are a presentation problem and this is the presentation, so
        // this is where it is answered rather than by moving the name the wire depends on.
        let isBloom = server == BridgeRegistration.serverName
        let label = tool.isEmpty
            ? (isBloom ? "Bloom" : server)
            : "\(isBloom ? "Bloom" : server): \(tool)"
        let glyph = isBloom ? "square.stack.3d.up" : "puzzlepiece.extension"

        // An MCP server can name a file as plainly as a built in tool does, and one that does gets
        // the same chip. Nothing here knows the server's schema, so the value has to survive the
        // guess before it is believed, which is what `ToolLiteral` does with it.
        if let path = ToolLiteral.of(name: name, input: input) {
            return ToolPresentation(
                glyph: glyph,
                label: label,
                detail: basename(path),
                tint: .neutral,
                chips: [.file(path: path)]
            )
        }

        return ToolPresentation(
            glyph: glyph,
            label: label,
            detail: firstScalar(input),
            tint: .neutral
        )
    }

    /// A tool Bloom has never heard of still has to read as a sentence, so the name goes in the
    /// label and the most likely looking argument goes in the detail. Never the JSON itself.
    private static func fallback(name: String, input: JSONValue) -> ToolPresentation {
        if let path = ToolLiteral.of(name: name, input: input) {
            return ToolPresentation(
                glyph: "wrench.and.screwdriver",
                label: name,
                detail: basename(path),
                tint: .neutral,
                chips: [.file(path: path)]
            )
        }

        return ToolPresentation(
            glyph: "wrench.and.screwdriver",
            label: name,
            detail: firstScalar(input),
            tint: .neutral
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

    // MARK: Text helpers

    public static func basename(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let last = trimmed.split(separator: "/").last else { return trimmed }
        return String(last)
    }

    /// Collapses every run of whitespace, so a heredoc or a multi line command still occupies
    /// exactly one row. The hard cap keeps a pathological command from costing real layout time.
    /// Counted rather than measured. `out.count` on a `String` walks it from the start, so asking
    /// it once per character made this quadratic: about 45,000 index steps for a 300 character
    /// cap, on a function `ToolRowView` calls inline in `body` with no cache, on every row, twice
    /// per pointer pass because that row holds `@State isHovered`.
    ///
    /// `text.utf8.count` for the reservation for the same reason: `text.count` walks the whole
    /// input to size a buffer that is capped at 301 anyway, and a byte count is an upper bound on
    /// a character count, which is all a reservation needs.
    public static func oneLine(_ text: String, limit: Int = 300) -> String {
        var out = ""
        out.reserveCapacity(min(text.utf8.count, limit + 1))
        var written = 0
        var pendingSpace = false

        for character in text {
            if character.isWhitespace {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace {
                out.append(" ")
                written += 1
                pendingSpace = false
            }
            out.append(character)
            written += 1
            if written >= limit { return out + "\u{2026}" }
        }
        return out
    }

    public static func firstLine(_ text: String) -> String {
        oneLine(text.prefix(while: { $0 != "\n" }).description)
    }

    public static func host(_ url: String) -> String {
        guard let parsed = URL(string: url) else { return oneLine(url) }
        return parsed.host() ?? oneLine(url)
    }

    /// `Git.countLines`, not a second rule.
    ///
    /// This counted a trailing newline as starting an empty last line, so a file written with one,
    /// which is nearly every file, was reported one line longer here than in the inspector beside
    /// it. The turn footer's rollup is built from this, so a turn that wrote three files read
    /// three lines heavier than the changed file list showed.
    public static func lineCount(_ text: String) -> Int {
        Git.countLines(text)
    }

    /// The first scalar in the input, keys in sorted order so the same tool always shows the same
    /// field rather than whatever the dictionary felt like today.
    public static func firstScalar(_ input: JSONValue) -> String {
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
