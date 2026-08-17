import SwiftUI
import BatonCore

/// One tool call compressed to the single line a collapsed transcript row shows.
///
/// The whole transcript design rests on this: an agent run is hundreds of actions, and the only
/// way to watch one is if every action costs exactly one line. So a presentation is a glyph, a
/// short label that names the intent, and a dimmed detail that names the target. Nothing here is
/// ever raw JSON, because a wall of braces is the thing this view exists to avoid.
struct ToolPresentation: Equatable {
    /// An SF Symbol name.
    var glyph: String
    var label: String
    var detail: String
    var tint: Color
    var chips: [String] = []
}

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

        var chips: [String] = []
        if !file.isEmpty { chips.append(file) }
        if let offset = input["offset"]?.intValue, offset > 0 { chips.append("from \(offset)") }
        if let pages = input["pages"]?.stringValue { chips.append("p\(pages)") }

        return ToolPresentation(glyph: "doc.text", label: label, detail: file, tint: Palette.accent, chips: chips)
    }

    private static func write(_ input: JSONValue) -> ToolPresentation {
        let file = basename(input["file_path"]?.stringValue ?? "")
        let lines = lineCount(input["content"]?.stringValue ?? "")

        var chips: [String] = []
        if !file.isEmpty { chips.append(file) }
        if lines > 0 { chips.append("\(lines) lines") }

        return ToolPresentation(
            glyph: "square.and.pencil",
            label: "Write",
            detail: file,
            tint: Palette.positive,
            chips: chips
        )
    }

    private static func edit(_ input: JSONValue) -> ToolPresentation {
        let file = basename(input["file_path"]?.stringValue ?? "")

        var chips: [String] = []
        if !file.isEmpty { chips.append(file) }
        if input["replace_all"]?.boolValue == true { chips.append("all") }

        return ToolPresentation(
            glyph: "pencil.line",
            label: "Edit",
            detail: file,
            tint: Palette.positive,
            chips: chips
        )
    }

    private static func multiEdit(_ input: JSONValue) -> ToolPresentation {
        let file = basename(input["file_path"]?.stringValue ?? "")
        let count = input["edits"]?.arrayValue?.count ?? 0

        var chips: [String] = []
        if !file.isEmpty { chips.append(file) }
        if count > 0 { chips.append("\(count) edits") }

        return ToolPresentation(
            glyph: "pencil.line",
            label: "Edit",
            detail: file,
            tint: Palette.positive,
            chips: chips
        )
    }

    private static func notebookEdit(_ input: JSONValue) -> ToolPresentation {
        let file = basename(input["notebook_path"]?.stringValue ?? "")

        var chips: [String] = []
        if !file.isEmpty { chips.append(file) }
        if let mode = input["edit_mode"]?.stringValue { chips.append(mode) }

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

        var chips: [String] = []
        if input["run_in_background"]?.boolValue == true { chips.append("background") }

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

        var chips: [String] = []
        if let filter = input["filter"]?.stringValue, !filter.isEmpty { chips.append(filter) }

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
        var chips: [String] = []
        if let path = input["path"]?.stringValue, !path.isEmpty { chips.append(basename(path)) }

        return ToolPresentation(
            glyph: "magnifyingglass",
            label: "Find files",
            detail: input["pattern"]?.stringValue ?? "",
            tint: Palette.accent,
            chips: chips
        )
    }

    private static func grep(_ input: JSONValue) -> ToolPresentation {
        var chips: [String] = []
        if let glob = input["glob"]?.stringValue, !glob.isEmpty { chips.append(glob) }
        if let path = input["path"]?.stringValue, !path.isEmpty { chips.append(basename(path)) }

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
        var chips: [String] = []
        if let model = input["model"]?.stringValue { chips.append(model) }
        if let isolation = input["isolation"]?.stringValue { chips.append(isolation) }

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
            chips: (input["agent_id"]?.stringValue).map { [$0] } ?? []
        )
    }

    // MARK: Planning and process

    private static func todos(_ input: JSONValue) -> ToolPresentation {
        let items = input["todos"]?.arrayValue ?? []
        let done = items.count { $0["status"]?.stringValue == "completed" }
        let active = items.first { $0["status"]?.stringValue == "in_progress" }
        let running = active?["activeForm"]?.stringValue ?? active?["content"]?.stringValue

        var chips: [String] = []
        if let running, !running.isEmpty { chips.append(oneLine(running, limit: 60)) }

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

        var chips: [String] = []
        if questions.count > 1 { chips.append("\(questions.count) questions") }

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
            chips: name.isEmpty ? [] : [name]
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
        let tool = parts.dropFirst().joined(separator: " ").replacingOccurrences(of: "_", with: " ")
        let label = tool.isEmpty ? server : "\(server): \(tool)"

        return ToolPresentation(
            glyph: "puzzlepiece.extension",
            label: label,
            detail: firstScalar(input),
            tint: Palette.synVariable
        )
    }

    /// A tool Baton has never heard of still has to read as a sentence, so the name goes in the
    /// label and the most likely looking argument goes in the detail. Never the JSON itself.
    private static func fallback(name: String, input: JSONValue) -> ToolPresentation {
        ToolPresentation(
            glyph: "wrench.and.screwdriver",
            label: name,
            detail: firstScalar(input),
            tint: Palette.textSecondary
        )
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

    static func lineCount(_ text: String) -> Int {
        text.isEmpty ? 0 : text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
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
        case .number(let number):
            return number == number.rounded() ? String(Int(number)) : String(number)
        case .bool(let flag): return flag ? "true" : "false"
        case .null, .array, .object: return nil
        }
    }
}
