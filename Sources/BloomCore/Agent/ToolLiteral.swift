import Foundation
import BloomClient

public typealias ToolLiteral = BloomClient.ToolLiteral

extension ToolLiteral {
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

}
