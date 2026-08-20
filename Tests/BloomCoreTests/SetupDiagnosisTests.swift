import Testing
@testable import BloomCore

@Suite("Reading a failed setup log")
struct SetupDiagnosisTests {
    /// The run that prompted all of this, copied out of the owner's own window.
    ///
    /// Three lines of a Valet site being set up, which worked, then `psql` failing twice, each
    /// time with its indented question underneath it. Everything about this log is ordinary: the
    /// failure is not last, the successful output is the majority of it, and the last line is a
    /// question rather than a fault.
    private let valet = """
    A [there-there-7] symbolic link has been created in [/Users/freek/.config/valet/Sites].
    Restarting nginx...
    The [there-there-7.test] site has been secured with a fresh TLS certificate.
    psql: error: connection to server at "127.0.0.1", port 5432 failed: Connection refused
    \tIs the server running on that host and accepting TCP/IP connections?
    psql: error: connection to server at "127.0.0.1", port 5432 failed: Connection refused
    \tIs the server running on that host and accepting TCP/IP connections?
    """

    private let psql =
        "psql: error: connection to server at \"127.0.0.1\", port 5432 failed: Connection refused"

    // MARK: The line that says what failed

    @Test("the summary is the error, not the question printed under it")
    func summaryIsTheError() {
        #expect(SetupDiagnosis.read(log: valet).summary == psql)
    }

    @Test("an indented line carries on the one above it and is never the failure")
    func continuationIsNotTheFailure() {
        #expect(SetupDiagnosis.isContinuation("\tIs the server running?"))
        #expect(SetupDiagnosis.isContinuation("    still the same error"))
        #expect(!SetupDiagnosis.isContinuation("psql: error: nope"))
        // A blank line is not a continuation. Nothing is being carried on.
        #expect(!SetupDiagnosis.isContinuation("   "))
    }

    @Test("a hint printed after the failure does not become the summary")
    func hintAfterTheFailure() {
        let log = """
        Building.
        cc: error: no such file or directory: 'main.c'
        Try 'cc --help' for more information.
        """
        #expect(SetupDiagnosis.read(log: log).summary == "cc: error: no such file or directory: 'main.c'")
    }

    @Test("the diagnostic format is a shape, not a vocabulary", arguments: [
        "psql: error: could not connect",
        "cc: fatal error: stdio.h: No such file or directory",
        "error: pathspec 'main' did not match any file",
        "FATAL: role \"bloom\" does not exist",
    ])
    func diagnosticShapes(line: String) {
        #expect(SetupDiagnosis.isDiagnostic(line))
    }

    @Test("ordinary output is not a diagnostic", arguments: [
        "Restarting nginx...",
        "The [there-there-7.test] site has been secured with a fresh TLS certificate.",
        "Installing dependencies",
        "\tIs the server running on that host and accepting TCP/IP connections?",
    ])
    func notDiagnostics(line: String) {
        #expect(!SetupDiagnosis.isDiagnostic(line))
    }

    @Test("with no diagnostic anywhere, the last line that starts a line of its own wins")
    func fallsBackToTheLastTopLevelLine() {
        let log = """
        Installing.
        make: *** [build] Error 2
        \tsee the log above
        """
        #expect(SetupDiagnosis.read(log: log).summary == "make: *** [build] Error 2")
    }

    @Test("a diagnostic far above the end cannot outrank what stopped the run")
    func reachIsBounded() {
        var log = "cc: error: a warning nobody acted on\n"
        for index in 0..<40 { log += "step \(index) done\n" }
        log += "make: *** [build] Error 2\n"
        #expect(SetupDiagnosis.read(log: log).summary == "make: *** [build] Error 2")
    }

    @Test("carriage returns do not end up inside the summary")
    func carriageReturns() {
        #expect(SetupDiagnosis.read(log: "one\r\npsql: error: refused\r\n").summary == "psql: error: refused")
    }

    @Test("an empty log diagnoses nothing rather than guessing")
    func emptyLog() {
        #expect(SetupDiagnosis.read(log: "").summary.isEmpty)
        #expect(SetupDiagnosis.read(log: "\n\n  \n").summary.isEmpty)
        #expect(SetupDiagnosis.read(log: "").advice.isEmpty)
    }

    // MARK: What to do about it

    @Test("connection refused names the host and port nothing was listening on")
    func connectionRefused() {
        let diagnosis = SetupDiagnosis.read(log: valet)
        #expect(diagnosis.advice == """
        Nothing was listening on 127.0.0.1:5432, which is where Postgres usually is. \
        Start it and run setup again.
        """)
    }

    @Test("the same failure from a tool that words it differently")
    func connectionRefusedFromCurl() {
        let log = "curl: (7) Failed to connect to localhost port 3000 after 2 ms: Connection refused"
        #expect(SetupDiagnosis.read(log: log).advice == """
        Nothing was listening on localhost:3000. Start it and run setup again.
        """)
    }

    @Test("a refusal that names no address still says what happened")
    func connectionRefusedWithNoAddress() {
        let advice = SetupDiagnosis.read(log: "error: Connection refused").advice
        #expect(advice == "Nothing was listening where the script tried to connect. Start it and run setup again.")
    }

    @Test("a command that is not there is named, whichever shell said so")
    func commandNotFound() {
        #expect(SetupDiagnosis.read(log: "setup.sh: line 12: psql: command not found").advice
            == "psql is not on the PATH the setup script ran with.")
        // zsh puts the name on the other side of the phrase, and the shell's own name first.
        #expect(SetupDiagnosis.read(log: "zsh: command not found: psql").advice
            == "psql is not on the PATH the setup script ran with.")
    }

    @Test("a failure nobody has a rule for gets a summary and no advice")
    func noAdviceIsFine() {
        let diagnosis = SetupDiagnosis.read(log: "Installing.\nmake: *** [build] Error 2")
        #expect(diagnosis.summary == "make: *** [build] Error 2")
        #expect(diagnosis.advice.isEmpty)
    }

    // MARK: Where the shell put it

    @Test("the script line comes out of the shell's own diagnostic")
    func scriptLine() {
        #expect(SetupDiagnosis.read(log: "setup.sh: line 12: psql: command not found").scriptLine == 12)
        #expect(SetupDiagnosis.read(log: valet).scriptLine == nil)
        #expect(SetupDiagnosis.scriptLine(in: "a: line ab: b") == nil)
        #expect(SetupDiagnosis.scriptLine(in: "a: line 7 b") == nil)
    }

    @Test("the sentence puts the remedy first and the line after it")
    func sentence() {
        let diagnosis = SetupDiagnosis.read(log: "setup.sh: line 12: psql: command not found", status: 127)
        #expect(diagnosis.sentence == """
        psql is not on the PATH the setup script ran with. The shell put it at line 12 of the script.
        """)
    }

    // MARK: The status

    @Test("the title carries the exit status when the run was watched")
    func title() {
        #expect(SetupDiagnosis.read(log: valet, status: 2).title == "Setup failed (2)")
        #expect(SetupDiagnosis.read(log: valet).title == "Setup failed")
    }

    // MARK: Which lines read as failure

    @Test("the successful output is not part of the failure")
    func onlyTheFailureIsMarked() {
        let lines = SetupLogLine.lines(of: valet, failing: psql)
        #expect(lines.map(\.isFailure) == [false, false, false, true, true, true, true])
    }

    @Test("output after a failure stops reading as one")
    func failureEndsAtTheNextTopLevelLine() {
        let log = """
        psql: error: refused
        \tIs the server running?
        Carrying on anyway.
        """
        #expect(SetupLogLine.lines(of: log, failing: "psql: error: refused").map(\.isFailure)
            == [true, true, false])
    }

    @Test("with nothing diagnosed, nothing is marked")
    func nothingMarked() {
        #expect(SetupLogLine.lines(of: "one\ntwo", failing: "").allSatisfy { !$0.isFailure })
    }

    @Test("the lines come back whole, so the block still reads as the log")
    func linesAreVerbatim() {
        let lines = SetupLogLine.lines(of: valet, failing: psql)
        #expect(lines.map(\.text).joined(separator: "\n") == valet)
    }

    @Test("scanning any log terminates", arguments: [
        "", "\n", "   ", "error:", ": line :", "port ", "at \"", "command not found: ",
        "a: command not found", "Connection refused", "\t", "\r\n",
    ])
    func fragmentsTerminate(fragment: String) {
        _ = SetupDiagnosis.read(log: fragment, status: 1)
        _ = SetupLogLine.lines(of: fragment, failing: "x")
    }
}
