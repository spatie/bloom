import Foundation
import Testing
@testable import BloomCore

@Suite("What a pane was running")
struct ProcessTableTests {
    /// The shape `ps -Ao pid=,ppid=,pgid=,args=` actually prints: right aligned numbers, and the
    /// command taking the whole rest of the line.
    private static let sample = """
              1     0     1 /sbin/launchd
          40123     1 40123 /bin/zsh -l
          40140 40123 40140 npm run dev
          40141 40123 40140 tee /tmp/dev.log
          40200     1 40200 /Applications/Something.app/Contents/MacOS/Something --flag
        """

    @Test("A line is three numbers and then everything else")
    func parsing() {
        let table = ProcessTable(psOutput: Self.sample)
        #expect(table.rows.count == 5)
        #expect(table.rows[2] == ProcessTable.Row(
            pid: 40140, parent: 40123, group: 40140, command: "npm run dev"
        ))
        // Spaces in the command are the normal case, not an edge one.
        #expect(table.rows[4].command == "/Applications/Something.app/Contents/MacOS/Something --flag")
    }

    @Test("A line that is not a process is dropped rather than guessed at")
    func rubbish() {
        let table = ProcessTable(psOutput: """
            PID PPID PGID ARGS
            12ab 1 1 not a pid
              7 1
              9 1 9
              11 1 11 fine
            """)
        #expect(table.rows.count == 1)
        #expect(table.rows.first?.command == "fine")
    }

    @Test("A shell with a job running answers with the job")
    func foreground() {
        let table = ProcessTable(psOutput: Self.sample)
        #expect(table.foregroundCommand(ofShell: 40123) == "npm run dev")
    }

    @Test("A shell at its prompt answers with nothing")
    func idle() {
        let table = ProcessTable(psOutput: """
              40123     1 40123 /bin/zsh -l
              40140     1 40140 npm run dev
            """)
        #expect(table.foregroundCommand(ofShell: 40123) == nil)
        // A pid nobody has, and the one that would match every orphan if it were not guarded.
        #expect(table.foregroundCommand(ofShell: 0) == nil)
        #expect(table.foregroundCommand(ofShell: 99999) == nil)
    }

    @Test("A child that leads no group is still better than no answer")
    func withoutJobControl() {
        let table = ProcessTable(psOutput: """
              40123     1 40123 /bin/sh
              40140 40123 40123 php artisan serve
            """)
        #expect(table.foregroundCommand(ofShell: 40123) == "php artisan serve")
    }

    /// The one thing a fixture cannot check: that the arguments and the parser agree with the `ps`
    /// on this machine. This test process is in its own table, under its own parent, so a column
    /// order that moved or a flag that stopped being accepted fails here rather than in a pane that
    /// quietly never remembers anything.
    @Test("The real ps answers in the shape the parser expects")
    func againstTheMachine() async throws {
        let table = try #require(await ProcessTable.current())
        let mine = try #require(table.rows.first { $0.pid == getpid() })
        #expect(mine.parent == getppid())
        #expect(!mine.command.isEmpty)
    }

    @Test("The newest of several jobs wins")
    func severalJobs() {
        let table = ProcessTable(psOutput: """
              40123     1 40123 /bin/zsh
              40140 40123 40140 npm run dev
              40190 40123 40190 php artisan serve
            """)
        #expect(table.foregroundCommand(ofShell: 40123) == "php artisan serve")
    }
}

@Suite("Which commands are worth offering back")
struct TerminalCommandMemoryTests {
    @Test("A pane keys its own command and nobody else's")
    func keys() {
        let one = TerminalCommandMemory.key(paneID: "a")
        #expect(one != TerminalCommandMemory.key(paneID: "b"))
        #expect(one == TerminalCommandMemory.key(paneID: "a"))
        #expect(one.hasPrefix("terminal.pane."))
    }

    @Test("A real command is offered", arguments: [
        "npm run dev",
        "php artisan serve",
        "composer dev",
        "bun run dev --host",
        "tail -f storage/logs/laravel.log",
        // A shell with arguments ran something, whatever the program is called.
        "zsh -c 'npm run dev'",
    ])
    func offered(command: String) {
        #expect(TerminalCommandMemory.offerable(command) == command)
    }

    /// A pane always has one of these in it, so a shell as the answer is the pane sitting idle.
    /// The leading dash is how a login shell reports itself.
    @Test("A bare shell is never offered", arguments: [
        "zsh", "-zsh", "bash", "-bash", "/bin/zsh", "/opt/homebrew/bin/fish", "sh", "  zsh  ",
    ])
    func bareShell(command: String) {
        #expect(TerminalCommandMemory.offerable(command) == nil)
    }

    @Test("Nothing at all is not a command")
    func empty() {
        #expect(TerminalCommandMemory.offerable(nil) == nil)
        #expect(TerminalCommandMemory.offerable("") == nil)
        #expect(TerminalCommandMemory.offerable("   \n ") == nil)
    }

    /// Pressing Start types the text into a shell, so a newline in it is a second command nobody
    /// read, and an escape sequence is whatever the terminal makes of it.
    @Test("A command carrying a control character is refused")
    func controlCharacters() {
        #expect(TerminalCommandMemory.offerable("npm run dev\nrm -rf /") == nil)
        #expect(TerminalCommandMemory.offerable("npm run dev\u{1b}[2J") == nil)
        #expect(TerminalCommandMemory.offerable("npm\trun dev") == nil)
    }

    @Test("A command too long to be one is refused")
    func tooLong() {
        let long = "node " + String(repeating: "a", count: TerminalCommandMemory.lengthLimit)
        #expect(TerminalCommandMemory.offerable(long) == nil)
        let atTheLimit = String(repeating: "a", count: TerminalCommandMemory.lengthLimit)
        #expect(TerminalCommandMemory.offerable(atTheLimit) == atTheLimit)
    }

    @Test("The trimmed text is what comes back, so a stored value round trips")
    func trimmed() {
        #expect(TerminalCommandMemory.offerable("  npm run dev\n") == "npm run dev")
    }

    /// The pane is not waiting for a command that has finished, and a memory that outlived its
    /// process would make every completed `git push` an offer on the next launch.
    @Test("A command that has already exited is not remembered")
    func exited() {
        #expect(TerminalCommandMemory.remembered(sent: "npm run dev", running: nil) == nil)
        #expect(TerminalCommandMemory.remembered(sent: nil, running: nil) == nil)
    }

    @Test("What Bloom sent wins over what the machine calls the same process")
    func sentWins() {
        let running = "node /opt/homebrew/lib/node_modules/npm/bin/npm-cli.js run dev"
        #expect(TerminalCommandMemory.remembered(sent: "npm run dev", running: running) == "npm run dev")
    }

    @Test("A command typed by hand is remembered as the machine reports it")
    func fallsBackToTheMachine() {
        #expect(TerminalCommandMemory.remembered(sent: nil, running: "php artisan serve")
            == "php artisan serve")
        // Bloom's own text is put through the same rules, so an unusable one falls through rather
        // than hiding what is really there.
        #expect(TerminalCommandMemory.remembered(sent: "a\nb", running: "php artisan serve")
            == "php artisan serve")
    }

    @Test("A shell running inside a shell is still a shell")
    func nestedShell() {
        #expect(TerminalCommandMemory.remembered(sent: nil, running: "-zsh") == nil)
    }
}
