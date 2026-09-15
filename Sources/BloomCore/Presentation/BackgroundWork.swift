import Foundation

/// The sentence under a finished turn that says the agent is not finished, and the one after an
/// archive that says what it stopped.
///
/// **The bug: "Completed in 5m 44s" with the tab still breathing.** The agent put a
/// `gh run watch` in the background, ended its turn with "#212 is still in CI, once it's green
/// I'll merge it", and the footer said Completed. The tab's activity mark stayed on, because
/// `SubagentRoster.isWorking` counted a backgrounded shell command as work in flight. Seven minutes
/// later the command finished and the CLI started a turn of its own. Nothing was wrong, and nothing
/// on screen said so: the only trace of the command was a truncated row forty lines up. The owner
/// took a screenshot and asked what was still going on.
///
/// The activity mark has since stopped counting commands, because a `serve` never finishes and
/// kept a workspace busy and unarchivable with no agent left in it. So this sentence is now the
/// only place a running command shows, which is the reason it stays.
///
/// Named rather than counted, because "1 background command" answers the question with another
/// one. `description` is the phrase the agent wrote for the Bash call, "Wait for the PR's Test run
/// to finish", which is exactly the sentence somebody wants here.
public enum BackgroundWork {
    /// More names than this and the sentence is a list, so the rest are counted.
    static let namedLimit = 3

    /// What is still running, or nil when nothing is.
    public static func note(for roster: SubagentRoster) -> String? {
        note(for: roster.subagents)
    }

    static func note(for subagents: [Subagent]) -> String? {
        let running = subagents.filter { $0.state == .running }
        guard case let (counted, names)? = described(running) else { return nil }
        let verb = running.count == 1 ? "is" : "are"
        return "\(capitalised(counted)) \(verb) still running: \(names)."
    }

    /// The notice after an archive that stopped background commands, or nil when it stopped none.
    ///
    /// An archive with nothing else at stake no longer asks before stopping a command, so this is
    /// where somebody finds out that the server on their port went with the workspace. Said after
    /// rather than asked before, because a dev server in a worktree about to be deleted is not a
    /// thing anybody would keep.
    public static func archived(_ workspaceName: String, stopping commands: [Subagent]) -> String? {
        guard case let (counted, names)? = described(commands) else { return nil }
        return "\(workspaceName) was archived. It stopped \(counted): \(names)."
    }

    /// "a background command" or "2 background commands", and the names that follow it.
    private static func described(_ subagents: [Subagent]) -> (counted: String, names: String)? {
        guard let first = subagents.first else { return nil }

        let noun = subagents.allSatisfy { $0.kind == first.kind } ? first.kind.noun : "background task"
        let counted = subagents.count == 1
            ? "\(article(for: noun)) \(noun)"
            : "\(subagents.count) \(plural(noun))"

        let titles = subagents.map(SubagentRow.title(of:))
        let named = Array(titles.prefix(namedLimit))
        let rest = titles.count - named.count
        let names = rest > 0
            ? named.joined(separator: ", ") + " and \(rest) more"
            : list(named)
        return (counted, names)
    }

    /// "a background command" rather than "1 background command", which reads as a count of
    /// something the sentence is about to name anyway.
    private static func article(for noun: String) -> String {
        noun.first.map { "aeiou".contains($0) } == true ? "an" : "a"
    }

    private static func capitalised(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    private static func plural(_ noun: String) -> String { noun + "s" }

    private static func list(_ items: [String]) -> String {
        guard items.count > 1, let last = items.last else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }
}
