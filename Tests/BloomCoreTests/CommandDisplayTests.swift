import Testing
import Foundation
@testable import BloomCore

/// Which `cd` a Bash row may hide, and the three that it may not.
///
/// The suite is organised by the case that decides the design rather than by the method: the
/// dangerous answer here is not a wrong string, it is a command that ran outside the workspace and
/// was drawn as though it ran inside it.
@Suite("Command display")
struct CommandDisplayTests {
    private static let worktree = "/Users/freek/bloom/workspaces/there-there/freekmurze-hibiki-sea"

    private static func of(_ command: String) -> CommandDisplay {
        CommandDisplay.of(command, worktree: worktree)
    }

    // MARK: 1. The worktree itself

    @Test("a cd to the worktree is dropped")
    func worktreeRoot() {
        let display = Self.of("cd \(Self.worktree) && ls tests/Http/Admin")
        #expect(display.place == .workspace)
        #expect(display.command == "ls tests/Http/Admin")
        #expect(display.lead == .none)
        #expect(display.line == "ls tests/Http/Admin")
    }

    @Test("a trailing slash on the cd is still the worktree")
    func trailingSlash() {
        #expect(Self.of("cd \(Self.worktree)/ && ls").place == .workspace)
    }

    @Test("a dot component in the cd is still the worktree")
    func dotComponent() {
        #expect(Self.of("cd \(Self.worktree)/./packages/../ && ls").place == .workspace)
    }

    @Test("a cd out and back again is where it ended up")
    func chain() {
        let display = Self.of("cd /tmp && cd \(Self.worktree) && composer test")
        #expect(display.place == .workspace)
        #expect(display.command == "composer test")
    }

    // MARK: 2. Inside the worktree

    @Test("a directory below the worktree keeps the part below")
    func subdirectory() {
        let display = Self.of("cd \(Self.worktree)/packages/api && npm test -- --runInBand")
        #expect(display.place == .subdirectory("packages/api"))
        #expect(display.lead == .location("packages/api"))
        #expect(display.command == "npm test -- --runInBand")
        #expect(display.leftTheWorkspace == false)
    }

    @Test("a relative cd resolves against the worktree, because that is where an agent stands")
    func relativeSubdirectory() {
        let display = Self.of("cd packages/api/src && rg --no-heading 'palette' -n")
        #expect(display.place == .subdirectory("packages/api/src"))
        #expect(display.command == "rg --no-heading 'palette' -n")
    }

    @Test("a chain of relative cds ends where the command ran")
    func relativeChain() {
        let display = Self.of("cd packages; cd api && npm test")
        #expect(display.place == .subdirectory("packages/api"))
        #expect(display.command == "npm test")
    }

    // MARK: 3. Somewhere else, which must stay obvious

    @Test("another workspace keeps its whole path, marked")
    func anotherWorkspace() {
        let command = "cd /Users/freek/bloom/workspaces/bloom/main && git log --oneline -5"
        let display = Self.of(command)
        #expect(display.leftTheWorkspace)
        #expect(display.lead == .prefix("cd /Users/freek/bloom/workspaces/bloom/main &&"))
        #expect(display.command == "git log --oneline -5")
        #expect(display.line == command)
    }

    @Test("a system path keeps its whole path, marked")
    func systemPath() {
        let display = Self.of("cd /tmp/build-cache && rm -rf artefacts")
        #expect(display.place == .elsewhere(prefix: "cd /tmp/build-cache &&"))
        #expect(display.command == "rm -rf artefacts")
    }

    @Test("a sibling whose name merely starts with the worktree's is outside it")
    func siblingPrefix() {
        #expect(Self.of("cd \(Self.worktree)-old && ls").leftTheWorkspace)
    }

    @Test("a relative cd above the worktree is outside it")
    func relativeAbove() {
        let display = Self.of("cd ../other && ls")
        #expect(display.place == .elsewhere(prefix: "cd ../other &&"))
        #expect(display.command == "ls")
    }

    @Test("a destination only a shell could work out is outside it, and nothing is hidden")
    func unresolvableDestinations() {
        for command in [
            "cd ~/bloom && ls",
            "cd $TMPDIR && ls",
            "cd \"$(git rev-parse --show-toplevel)\" && ls",
            "cd `pwd`/build && ls",
            "cd - && ls",
        ] {
            let display = Self.of(command)
            #expect(display.leftTheWorkspace, "\(command)")
            // No prefix, because there is none this could honestly point at.
            #expect(display.lead == .none, "\(command)")
            #expect(display.command == command, "\(command)")
        }
    }

    @Test("a cd out and then deeper is outside, however far it walks")
    func chainLeavingTheWorktree() {
        let display = Self.of("cd \(Self.worktree) && cd /var/log && tail -n 20 system.log")
        #expect(display.leftTheWorkspace)
        #expect(display.command == "tail -n 20 system.log")
        #expect(display.lead == .prefix("cd \(Self.worktree) && cd /var/log &&"))
    }

    @Test("a chain separated by newlines keeps its command, because a row is one line tall")
    func chainOverNewlines() {
        let display = Self.of("cd /tmp\ncd /var/log\ntail -n 20 system.log")
        #expect(display.command == "tail -n 20 system.log")
        // Collapsed, not raw. Drawn raw, the newline in the middle of it took the command with it.
        #expect(display.lead == .prefix("cd /tmp cd /var/log"))
        #expect(!display.line.contains("\n"))
    }

    @Test("a prefix nobody could read is cut, the way a command is")
    func absurdPrefix() {
        let display = Self.of("cd /" + String(repeating: "a", count: 400) + " && ls")
        #expect(display.lead.text.count <= 301)
        #expect(display.command == "ls")
    }

    // MARK: 4. No cd at all

    @Test("a command with no cd is untouched")
    func noPrefix() {
        let display = Self.of("git diff --stat")
        #expect(display.place == .unstated)
        #expect(display.command == "git diff --stat")
        #expect(display.lead == .none)
    }

    @Test("a command that merely mentions cd is untouched")
    func mentionsCD() {
        for command in ["echo cd /tmp", "cdk deploy", "cd", "git cd-log"] {
            #expect(Self.of(command).place == .unstated, "\(command)")
        }
    }

    @Test("a bare cd to the worktree keeps its own text, because a row is never blank")
    func nothingAfterTheCD() {
        let command = "cd \(Self.worktree)"
        #expect(Self.of(command) == CommandDisplay(place: .unstated, command: command))
    }

    @Test("a bare cd away keeps its own text and is still outside")
    func bareCDAway() {
        // Not quiet, and this is why: the Bash tool holds one shell across calls, so this moves
        // the directory for every row after it.
        let display = Self.of("cd /tmp")
        #expect(display.place == .elsewhere(prefix: ""))
        #expect(display.command == "cd /tmp")
        #expect(display.lead == .none)
    }

    // MARK: 5. Separators and quoting

    @Test("and, semicolon and newline all end the prefix")
    func separators() {
        for separator in [" && ", "; ", "\n", " ;\n", "&&\n  "] {
            let display = Self.of("cd \(Self.worktree)\(separator)php artisan tinker")
            #expect(display.place == .workspace, "\(separator.debugDescription)")
            #expect(display.command == "php artisan tinker", "\(separator.debugDescription)")
        }
    }

    @Test("a heredoc after a newline keeps every line of itself")
    func heredoc() {
        let body = "python3 - <<'PYEOF'\nimport json\nPYEOF"
        let display = Self.of("cd \(Self.worktree)\n\(body)")
        #expect(display.place == .workspace)
        #expect(display.command == body)
    }

    @Test("a quoted path is unquoted before it is compared")
    func quoted() {
        for command in [
            "cd '\(Self.worktree)' && composer test",
            "cd \"\(Self.worktree)\" && composer test",
        ] {
            let display = Self.of(command)
            #expect(display.place == .workspace, "\(command)")
            #expect(display.command == "composer test", "\(command)")
        }
    }

    @Test("a path with a space in it is read, quoted or escaped")
    func spaces() {
        let spaced = "/Users/freek/bloom/workspaces/there there/hibiki sea"
        for command in [
            "cd '\(spaced)' && ls",
            "cd \"\(spaced)\" && ls",
            "cd /Users/freek/bloom/workspaces/there\\ there/hibiki\\ sea && ls",
        ] {
            let display = CommandDisplay.of(command, worktree: spaced)
            #expect(display.place == .workspace, "\(command)")
            #expect(display.command == "ls", "\(command)")
        }
    }

    @Test("a quoted subdirectory keeps the part below the worktree")
    func quotedSubdirectory() {
        let display = Self.of("cd \"\(Self.worktree)/packages/api\" && npm test")
        #expect(display.place == .subdirectory("packages/api"))
    }

    @Test("an unbalanced quote is not guessed at")
    func unbalancedQuote() {
        let command = "cd '\(Self.worktree) && ls"
        let display = Self.of(command)
        #expect(display.leftTheWorkspace)
        #expect(display.command == command)
    }

    @Test("a cd this cannot treat as a prefix is left alone")
    func notAPrefix() {
        // `||` means the cd may have failed, `&` backgrounds it, and a second argument is not a
        // path at all.
        for command in [
            "cd \(Self.worktree) || echo missing",
            "cd \(Self.worktree) & ls",
            "cd \(Self.worktree) extra && ls",
        ] {
            let display = Self.of(command)
            #expect(display.place == .unstated, "\(command)")
            #expect(display.command == command, "\(command)")
        }
    }

    // MARK: The worktree itself

    @Test("no worktree to compare against means nothing is hidden")
    func noWorktree() {
        for worktree in ["", "relative/path", "/"] {
            let command = "cd /anywhere && ls"
            let display = CommandDisplay.of(command, worktree: worktree)
            #expect(display == CommandDisplay(place: .unstated, command: command), "\(worktree)")
        }
    }

    @Test("a worktree written with a trailing slash still matches")
    func worktreeTrailingSlash() {
        let display = CommandDisplay.of("cd \(Self.worktree) && ls", worktree: Self.worktree + "/")
        #expect(display.place == .workspace)
    }

    // MARK: What the row is left with

    @Test("the command keeps its own leading whitespace off, and nothing else is trimmed")
    func remainderIsTrimmedOnce() {
        let display = Self.of("  cd \(Self.worktree)   &&    ls -la   ")
        #expect(display.command == "ls -la   ")
    }

    // MARK: What a Bash row is built from

    @Test("a Bash row hides the prefix and still copies the whole command")
    func bashRow() {
        let input = JSONValue.object([
            "description": .string("List admin tests"),
            "command": .string("cd \(Self.worktree)\nls tests/Http/Admin"),
        ])
        let row = ToolPresenter.present(name: "Bash", input: input, worktree: Self.worktree)
        #expect(row.label == "List admin tests")
        #expect(row.detail == "ls tests/Http/Admin")
        #expect(row.detailLead == .none)
        #expect(row.tint == .neutral)
        // The copy and the expanded body are the record, so they keep the `cd`.
        #expect(row.literal == "cd \(Self.worktree)\nls tests/Http/Admin")
    }

    @Test("a Bash row that ran elsewhere keeps its path and says so")
    func bashRowElsewhere() {
        let command = "cd /tmp/build-cache && rm -rf artefacts"
        let input = JSONValue.object(["command": .string(command)])
        let row = ToolPresenter.present(name: "Bash", input: input, worktree: Self.worktree)
        #expect(row.detailLead == .prefix("cd /tmp/build-cache &&"))
        #expect(row.detail == "rm -rf artefacts")
        #expect(row.detailLine == command)
        // On the glyph, at the left edge, which is the column a reader scans.
        #expect(row.tint == .warning)
    }

    @Test("a Bash row whose destination could not be read is marked too")
    func bashRowOpaque() {
        for command in ["cd ~/bloom && ls", "cd $TMPDIR && ls", "cd /tmp"] {
            let input = JSONValue.object(["command": .string(command)])
            let row = ToolPresenter.present(name: "Bash", input: input, worktree: Self.worktree)
            #expect(row.tint == .warning, "\(command)")
            #expect(row.detail == command, "\(command)")
            #expect(row.detailLead == .none, "\(command)")
        }
    }

    @Test("a Bash row below the worktree keeps the part below")
    func bashRowSubdirectory() {
        let input = JSONValue.object(["command": .string("cd \(Self.worktree)/packages/api && npm test")])
        let row = ToolPresenter.present(name: "Bash", input: input, worktree: Self.worktree)
        #expect(row.detailLead == .location("packages/api"))
        #expect(row.detail == "npm test")
    }

    @Test("with no worktree to compare against a Bash row is what it always was")
    func bashRowWithoutAWorkspace() {
        let command = "cd \(Self.worktree) && ls"
        let row = ToolPresenter.present(name: "Bash", input: .object(["command": .string(command)]))
        #expect(row.detail == command)
        #expect(row.detailLead == .none)
    }

    @Test("a location is drawn as a tag and a prefix as part of the command")
    func leads() {
        #expect(CommandDisplay.Lead.none.text.isEmpty)
        #expect(CommandDisplay.Lead.location("packages/api").tint == .accent)
        #expect(CommandDisplay.Lead.prefix("cd /tmp &&").tint == .warning)
        #expect(CommandDisplay.Lead.prefix("cd /tmp &&").joiner == " ")
        #expect(CommandDisplay.Lead.location("packages/api").joiner.contains("\u{203A}"))
    }
}
