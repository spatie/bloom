import Foundation

/// A `/command` the composer can offer.
///
/// Bloom ships almost no list of its own. What exists is whatever the Claude Code CLI would
/// resolve for this checkout, and that is spread over six places on disk which change while the
/// app is running without anything telling us. So this is read, never modelled.
public struct SlashCommand: Identifiable, Hashable, Sendable {
    /// Where the entry came from, which is what decides precedence and what the row badges.
    public enum Scope: Hashable, Sendable {
        /// Built into the CLI itself. Not discoverable on disk, so this is a short hand kept list.
        case builtIn
        /// `~/.claude`, so it is available in every checkout.
        case user
        /// `<checkout>/.claude`, so it belongs to this repository.
        case project
        /// An enabled plugin, named by its own `plugin.json`.
        case plugin(String)
    }

    /// A markdown command file and a skill directory are invoked the same way and are told apart
    /// only for the sake of a sensible tie break, since a command is the more specific thing.
    public enum Kind: Hashable, Sendable {
        case command
        case skill
    }

    /// Without the leading slash, and colon namespaced exactly the way the CLI writes it:
    /// `commit`, `git:commit`, `superpowers:brainstorming`.
    public var name: String
    /// One line, from `description:` in the YAML frontmatter where there is one.
    public var detail: String
    public var kind: Kind
    public var scope: Scope
    /// The markdown file this came from, absolute. Nil for a built in, which is compiled into the
    /// CLI and has no file to preview or to open.
    public var path: String?

    public var id: String { name }

    public init(name: String, detail: String, kind: Kind, scope: Scope, path: String? = nil) {
        self.name = name
        self.detail = detail
        self.kind = kind
        self.scope = scope
        self.path = path
    }

    /// The one word the menu row prints after the description, or nothing.
    ///
    /// Only this repository's own entries earn one. A plugin already says which plugin it is in
    /// the name, and everything else is the user's own and needs no explaining.
    public var badge: String? {
        scope == .project ? "project" : nil
    }
}

/// One ranked row: the command, why it ranked there, and which of its characters the query hit.
public struct SlashCommandMatch: Identifiable, Hashable, Sendable {
    public var command: SlashCommand
    public var score: Int
    /// Character offsets into `command.name`, ascending. May be empty.
    public var highlights: [Int]

    public var id: String { command.id }

    public init(command: SlashCommand, score: Int, highlights: [Int]) {
        self.command = command
        self.score = score
        self.highlights = highlights
    }
}

extension SlashCommand {
    /// Ranks a whole catalogue against the text typed after the `/`.
    ///
    /// Fuzzy, not prefix: `revi` has to find `code-review` and `security-review`, and the part
    /// after the colon of `superpowers:requesting-code-review` has to find the whole thing.
    ///
    /// Pure and nonisolated, so the composer can call it straight from a view body. A few hundred
    /// short names is small enough that taking it off the main actor would cost more than it saved.
    public static func rank(_ commands: [SlashCommand], query: String) -> [SlashCommandMatch] {
        guard !query.isEmpty else {
            return commands.map { SlashCommandMatch(command: $0, score: 0, highlights: []) }
        }

        var found: [SlashCommandMatch] = []
        found.reserveCapacity(commands.count)

        for command in commands {
            guard let hit = FuzzyMatch.hit(command.name, query: query) else { continue }
            found.append(SlashCommandMatch(
                command: command,
                // A command file is the more specific thing than a skill of the same name, and
                // this is only ever reached when the two scored dead level anyway.
                score: hit.score + (command.kind == .command ? 1 : 0),
                highlights: hit.positions
            ))
        }

        found.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.command.name < rhs.command.name
        }
        return found
    }
}
