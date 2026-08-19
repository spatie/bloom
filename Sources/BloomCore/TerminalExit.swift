import Foundation

/// How a shell in a terminal pane ended, and whether the pane it was running in should close.
///
/// The status handed over by SwiftTerm is the raw value `waitpid` fills in, not an exit code, and
/// the two are not the same number: `exit 3` arrives here as 768, and a shell killed with SIGTERM
/// arrives as 15. Decoding it is the whole reason this type exists, because a pane that prints
/// "exit 768" after `exit 3` is telling the user something that is not true.
public enum TerminalExit: Sendable, Hashable {
    /// The process ended by itself, with the status it passed to `exit`.
    case exited(Int32)
    /// The process was killed, by the signal named here.
    case killed(Int32)
    /// The end could not be read: the pty failed, or the process never started at all.
    case unknown

    /// Decodes a `waitpid` status, or `nil` for the case SwiftTerm reports when it never got one.
    public init(waitStatus: Int32?) {
        guard let status = waitStatus else {
            self = .unknown
            return
        }

        // The layout is fixed by the C library: the low seven bits are the signal that killed the
        // process, zero when it exited by itself, and 0x7F when it only stopped. Bit 0x80 says a
        // core was dumped and says nothing about which signal it was.
        let signal = status & 0x7F
        switch signal {
        case 0: self = .exited((status >> 8) & 0xFF)
        case 0x7F: self = .unknown
        default: self = .killed(signal)
        }
    }

    /// Whether the pane holding this shell should close itself.
    ///
    /// Only a clean exit closes it. This is the rule macOS Terminal ships as "Close if the shell
    /// exited cleanly", and the distinction it draws is the one that matters: typing `exit` means
    /// you are done with the pane, while a shell that died with a status or under a signal has
    /// left the reason on screen, and that is the one moment the output is worth reading. Closing
    /// there would throw away the only evidence of what went wrong.
    public var closesPane: Bool {
        self == .exited(0)
    }

    /// The line the pane prints under the last of the shell's output.
    ///
    /// Never shown for a clean exit, which closes the pane instead, but written out anyway for the
    /// terminals that host one command and stay open whatever it did.
    public var paneMessage: String {
        switch self {
        case .exited(0), .unknown:
            "Process finished"
        case .exited(let status):
            "Process finished with status \(status)"
        case .killed(let signal):
            "Process killed by \(Self.name(ofSignal: signal))"
        }
    }

    /// The name a shell would print for a signal, so the pane says `SIGTERM` rather than `15`.
    /// Anything outside the list is named by its number, which is still more use than nothing.
    static func name(ofSignal signal: Int32) -> String {
        let names: [Int32: String] = [
            SIGHUP: "SIGHUP",
            SIGINT: "SIGINT",
            SIGQUIT: "SIGQUIT",
            SIGILL: "SIGILL",
            SIGTRAP: "SIGTRAP",
            SIGABRT: "SIGABRT",
            SIGFPE: "SIGFPE",
            SIGKILL: "SIGKILL",
            SIGBUS: "SIGBUS",
            SIGSEGV: "SIGSEGV",
            SIGSYS: "SIGSYS",
            SIGPIPE: "SIGPIPE",
            SIGALRM: "SIGALRM",
            SIGTERM: "SIGTERM",
            SIGXCPU: "SIGXCPU",
            SIGXFSZ: "SIGXFSZ",
        ]
        return names[signal] ?? "signal \(signal)"
    }
}
