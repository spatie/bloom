import Foundation

/// The sentence under a finished turn that says the agent is not finished.
///
/// **The bug: "Completed in 5m 44s" with the tab still breathing.** The agent put a
/// `gh run watch` in the background, ended its turn with "#212 is still in CI, once it's green
/// I'll merge it", and the footer said Completed. The tab's activity mark stayed on, because
/// `SubagentRoster.isWorking` counts a backgrounded shell command as work in flight, which it is.
/// Seven minutes later the command finished and the CLI started a turn of its own. Nothing was
/// wrong, and nothing on screen said so: the only trace of the command was a truncated row forty
/// lines up. The owner took a screenshot and asked what was still going on.
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
        guard let first = running.first else { return nil }

        let noun = running.allSatisfy { $0.kind == first.kind } ? first.kind.noun : "background task"
        let subject = running.count == 1
            ? "\(article(for: noun)) \(noun) is"
            : "\(running.count) \(plural(noun)) are"

        let titles = running.map(SubagentRow.title(of:))
        let named = Array(titles.prefix(namedLimit))
        let rest = titles.count - named.count
        let names = rest > 0
            ? named.joined(separator: ", ") + " and \(rest) more"
            : list(named)

        return "\(subject) still running: \(names)."
    }

    /// "A background command is" rather than "1 background command is", which reads as a count
    /// of something the sentence is about to name anyway.
    private static func article(for noun: String) -> String {
        noun.first.map { "aeiou".contains($0) } == true ? "An" : "A"
    }

    private static func plural(_ noun: String) -> String { noun + "s" }

    private static func list(_ items: [String]) -> String {
        guard items.count > 1, let last = items.last else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }
}
