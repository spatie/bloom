import Testing
import Foundation
@testable import BloomCore

@Suite("TerminalExit")
struct TerminalExitTests {
    @Test("a clean exit is read as status zero")
    func cleanExit() {
        #expect(TerminalExit(waitStatus: 0) == .exited(0))
    }

    @Test("a status is read out of the high byte, not off the raw number")
    func nonZeroExit() {
        // What `exit 3` actually hands to waitpid. Reading the raw value would say 768.
        #expect(TerminalExit(waitStatus: 3 << 8) == .exited(3))
        #expect(TerminalExit(waitStatus: 127 << 8) == .exited(127))
        #expect(TerminalExit(waitStatus: 255 << 8) == .exited(255))
    }

    @Test("a signal is read out of the low seven bits")
    func killed() {
        #expect(TerminalExit(waitStatus: SIGTERM) == .killed(SIGTERM))
        #expect(TerminalExit(waitStatus: SIGKILL) == .killed(SIGKILL))
        #expect(TerminalExit(waitStatus: SIGHUP) == .killed(SIGHUP))
    }

    @Test("the core dump bit does not change which signal it was")
    func coreDumped() {
        #expect(TerminalExit(waitStatus: SIGSEGV | 0x80) == .killed(SIGSEGV))
    }

    @Test("a process that only stopped has not ended")
    func stopped() {
        #expect(TerminalExit(waitStatus: 0x7F) == .unknown)
    }

    @Test("no status at all is unknown")
    func noStatus() {
        #expect(TerminalExit(waitStatus: nil) == .unknown)
    }

    @Test("only a clean exit closes the pane")
    func closesOnCleanExitOnly() {
        #expect(TerminalExit.exited(0).closesPane)
        #expect(!TerminalExit.exited(1).closesPane)
        #expect(!TerminalExit.exited(127).closesPane)
        #expect(!TerminalExit.killed(SIGTERM).closesPane)
        #expect(!TerminalExit.killed(SIGKILL).closesPane)
        #expect(!TerminalExit.unknown.closesPane)
    }

    @Test("the pane that stays open says what ended the shell")
    func message() {
        #expect(TerminalExit.exited(3).paneMessage == "Process finished with status 3")
        #expect(TerminalExit.killed(SIGKILL).paneMessage == "Process killed by SIGKILL")
        #expect(TerminalExit.killed(SIGTERM).paneMessage == "Process killed by SIGTERM")
        #expect(TerminalExit.unknown.paneMessage == "Process finished")
    }

    @Test("a signal nobody has a name for is named by its number")
    func unnamedSignal() {
        #expect(TerminalExit.killed(64).paneMessage == "Process killed by signal 64")
    }
}
