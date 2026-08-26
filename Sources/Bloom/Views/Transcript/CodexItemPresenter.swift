import SwiftUI
import BloomCore

/// Turns one Codex thread item into the single line a collapsed transcript row shows.
///
/// A separate presenter rather than more cases in `ToolPresenter`, which is 535 lines of Claude
/// Code tool names. **Codex has no tool names.** It has ten item types with typed payloads, so
/// there is nothing to switch on that the other presenter could recognise, and the two vocabularies
/// share only their glyphs. Adding Codex cases to a function that switches on `Read`, `Write`,
/// `MultiEdit` and `Bash` would mean a name collision per case and a file nobody can read.
///
/// What they do share is `ToolPresentation`. A row is a glyph, a label naming the intent and a
/// dimmed detail naming the target, whichever agent produced it, and that is the whole reason a
/// Codex chat and a Claude chat look like one app rather than two.
enum CodexItemPresenter {
    /// Nil when this call did not come from Codex, so a caller can fall through to `ToolPresenter`
    /// without knowing which backend a row belongs to.
    ///
    /// Read off the payload rather than off the session, deliberately: a transcript drawn from the
    /// database alone still knows which vocabulary each row is in, with no join and no column that
    /// did not exist when the row was written.
    static func present(_ use: AgentToolUse, worktree: String = "") -> ToolPresentation? {
        guard let item = CodexTranslation.item(in: use.input) else { return nil }
        return present(item, worktree: worktree)
    }

    /// The row, and then the same core question a Claude row asks: what the argument literally is.
    /// A Codex command must read as a command in exactly the face a Claude one does, or the two
    /// backends stop looking like one transcript.
    static func present(_ item: CodexItem, worktree: String = "") -> ToolPresentation {
        var presentation = shape(item, worktree: worktree)
        presentation.literal = ToolLiteral.of(codex: item)
        return presentation
    }

    private static func shape(_ item: CodexItem, worktree: String) -> ToolPresentation {
        switch item {
        case .commandExecution(let run): command(run, worktree: worktree)
        case .fileChange(let change): fileChange(change)
        case .mcpToolCall(let call): mcp(call)
        case .webSearch(let search): webSearch(search)
        case .plan(let plan): self.plan(plan)
        case .subAgentActivity(let activity): subAgent(activity)
        case .contextCompaction: compaction()
        case .other(let type, _, let json): other(type: type, json: json)
        // Prose, drawn as prose. These never reach a tool row, and a presentation for them would
        // be a row that should not exist.
        case .userMessage, .agentMessage, .reasoning:
            ToolPresentation(
                glyph: "text.alignleft",
                label: "Message",
                detail: "",
                tint: .neutral
            )
        }
    }

    // MARK: - Items

    /// Codex wraps everything in the login shell, so the command as sent reads
    /// `/bin/zsh -lc 'git status'`. What the user asked for is inside the quotes, and that is what
    /// the row shows: the wrapper is the same on every line and says nothing.
    private static func command(_ run: CodexCommandExecution, worktree: String) -> ToolPresentation {
        // Codex opens its commands with the same `cd` a Claude row does, so it is hidden by the
        // same rule. Asked before the one line collapse; see `CommandDisplay`.
        let display = CommandDisplay.of(ToolLiteral.unwrapShell(run.command), worktree: worktree)
        let command = ToolPresenter.oneLine(display.command)

        var chips: [ToolChip] = []
        if let code = run.exitCode, code != 0 { chips.append(.code("exit \(code)")) }
        if run.status == .declined { chips.append(.code("declined")) }

        // Failure first: a command that went wrong is more urgent than one that went elsewhere.
        let tint: ToolTint = switch (run.status, display.leftTheWorkspace) {
        case (.failed, _): .negative
        case (_, true): .warning
        default: .neutral
        }

        return ToolPresentation(
            glyph: "terminal",
            label: "Shell",
            detail: command,
            tint: tint,
            chips: chips,
            detailLead: display.lead
        )
    }

    /// A patch, which for a person is one of three verbs rather than the word "fileChange". One
    /// file names it, several count.
    private static func fileChange(_ change: CodexFileChange) -> ToolPresentation {
        let label = change.changes.count == 1
            ? (change.changes[0].kind.label)
            : "Patch"
        let detail = change.changes.count == 1
            ? ToolPresenter.basename(change.changes[0].path)
            : "\(change.changes.count) files"

        var chips: [ToolChip] = []
        if change.changes.count == 1 {
            chips.append(.file(path: change.changes[0].path))
        }
        if change.status == .declined { chips.append(.code("declined")) }

        return ToolPresentation(
            glyph: glyph(for: change),
            label: label,
            detail: detail,
            tint: tint(for: change.status),
            chips: chips
        )
    }

    private static func glyph(for change: CodexFileChange) -> String {
        guard change.changes.count == 1 else { return "square.stack.3d.up" }
        switch change.changes[0].kind {
        case .add: return "doc.badge.plus"
        case .delete: return "trash"
        case .update(let movedTo): return movedTo == nil ? "pencil.line" : "arrow.right.doc.on.clipboard"
        case .unknown: return "doc"
        }
    }

    /// A refusal is not a failure. Nothing broke: somebody said no, and the row must not be the
    /// same alarming red as a command that crashed.
    private static func tint(for status: CodexRunStatus) -> ToolTint {
        switch status {
        case .failed: .negative
        // Declined is not a failure and not an outcome: nothing ran. It takes the quiet role the
        // rest of the transcript's "nothing to report" rows take.
        case .declined: .neutral
        default: .positive
        }
    }

    /// Spelled the way `ToolPresenter` spells an MCP call, because there it really is the same
    /// tool reached through the same protocol.
    private static func mcp(_ call: CodexMcpToolCall) -> ToolPresentation {
        let tool = call.tool.replacing("_", with: " ")
        return ToolPresentation(
            glyph: "puzzlepiece.extension",
            label: tool.isEmpty ? call.server : "\(call.server): \(tool)",
            detail: call.errorMessage ?? "",
            tint: call.status == .failed ? .negative : .neutral
        )
    }

    private static func webSearch(_ search: CodexWebSearch) -> ToolPresentation {
        switch search.action {
        case "openPage":
            return ToolPresentation(
                glyph: "safari",
                label: "Open page",
                detail: search.url ?? search.query,
                tint: .neutral
            )
        case "findInPage":
            return ToolPresentation(
                glyph: "text.magnifyingglass",
                label: "Find in page",
                detail: search.query,
                tint: .neutral
            )
        default:
            return ToolPresentation(
                glyph: "magnifyingglass",
                label: "Search the web",
                detail: search.query,
                tint: .neutral
            )
        }
    }

    private static func plan(_ plan: CodexPlan) -> ToolPresentation {
        ToolPresentation(
            glyph: "list.bullet.rectangle",
            label: "Plan",
            detail: ToolPresenter.oneLine(firstLine(of: plan.text)),
            tint: .neutral
        )
    }

    private static func subAgent(_ activity: CodexSubAgentActivity) -> ToolPresentation {
        ToolPresentation(
            glyph: "person.2",
            label: "Sub-agent",
            detail: ToolPresenter.basename(activity.agentPath),
            tint: .neutral,
            chips: activity.kind.isEmpty ? [] : [.code(activity.kind)]
        )
    }

    private static func compaction() -> ToolPresentation {
        ToolPresentation(
            glyph: "arrow.down.right.and.arrow.up.left",
            label: "Compacted the conversation",
            detail: "",
            tint: .neutral
        )
    }

    /// An item type nobody has written a reading for yet. Named rather than hidden, because a row
    /// that says `sleep` is more use than a row that is not there, and Codex ships new item types
    /// the way Claude Code ships new tools.
    private static func other(type: String, json: JSONValue) -> ToolPresentation {
        ToolPresentation(
            glyph: "questionmark.square.dashed",
            label: spaced(type),
            detail: ToolPresenter.oneLine(summary(of: json)),
            tint: .neutral
        )
    }

    // MARK: - Helpers

    /// `imageGeneration` reads as "Image generation". The wire name is camel case and a row is
    /// read by a person.
    static func spaced(_ type: String) -> String {
        var out = ""
        for character in type {
            if character.isUppercase, !out.isEmpty { out.append(" ") }
            out.append(out.isEmpty ? Character(character.uppercased()) : character)
        }
        return out
    }

    /// The one field of an unknown payload worth putting on the line. Never the whole object: a
    /// wall of braces is the thing a transcript row exists to avoid.
    static func summary(of json: JSONValue) -> String {
        for key in ["path", "query", "command", "text", "tool", "prompt"] {
            if let value = json[key]?.stringValue, !value.isEmpty { return value }
        }
        return ""
    }

    static func firstLine(of text: String) -> String {
        text.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
    }
}

// MARK: - Routing

/// Which presenter draws a call.
///
/// One call site rather than a decision spread through the transcript views, and the switch is on
/// the row's own payload rather than on the session, so a transcript loaded from the database
/// draws correctly before anything has looked up which backend the chat is on.
///
/// The rows themselves are shared and need no change: `ToolRowView`, `ExpandableRow`,
/// `DetailCodeBlock` and `ToolResultView` all draw a `ToolPresentation` and do not care where it
/// came from.
enum TranscriptPresenter {
    static func present(_ use: AgentToolUse, worktree: String = "") -> ToolPresentation {
        CodexItemPresenter.present(use, worktree: worktree) ?? ToolPresenter.present(use, worktree: worktree)
    }

    static func present(name: String, input: JSONValue, worktree: String = "") -> ToolPresentation {
        if let item = CodexTranslation.item(in: input) {
            return CodexItemPresenter.present(item, worktree: worktree)
        }
        return ToolPresenter.present(name: name, input: input, worktree: worktree)
    }
}
