import AppKit
import BloomCore

/// A sign-in on a Bloom Server, shown as the step it is on rather than as the terminal it runs in.
///
/// This used to be a raw terminal over SSH, and on a server every CLI takes its fallback path:
/// npm's notices while it installed, "Opening browser to sign in" from a machine with no screen,
/// then an OAuth address wrapped over seven rows to be selected by hand. The terminal still runs
/// and still owns the conversation. This reads it (`RemoteSignInReading`), turns the part a person
/// has to act on into a button and a text field, and writes their answer back into the same pty.
/// Anything it does not recognise opens the terminal, which is where that answer was always going
/// to be typed.
@MainActor
@Observable
final class ServerSignInSession {
    enum Verdict: Equatable { case pending, checking, signedIn, stillSignedOut }

    let account: RemoteSignInAccount
    let host: String
    private(set) var terminal: LoginTerminalSession?
    private(set) var step: RemoteSignInStep = .connecting
    private(set) var verdict: Verdict = .pending
    /// Set once success has been on screen long enough to read, which is the sheet's cue to close.
    private(set) var isComplete = false
    private(set) var hasOpenedLink = false
    var pastedCode = ""
    var showsTerminal = false

    @ObservationIgnored private let launch: TerminalLaunch
    @ObservationIgnored private let setup: ServerSetupModel
    @ObservationIgnored private var exit: TerminalExit?
    @ObservationIgnored private var isReadScheduled = false
    @ObservationIgnored private var hasRepliedAutomatically = false
    @ObservationIgnored private var unrecognisedSince: ContinuousClock.Instant?

    /// The same pause `GitHubSignInSheet` holds its success for.
    private static let successPause = Duration.milliseconds(700)
    /// Output arrives in bursts of small writes, and one read per burst is plenty.
    private static let readDelay = Duration.milliseconds(120)
    /// Codex prints "Follow these steps to sign in ... authorization:" a write before the address
    /// under it, and a line ending in a colon reads as a question. One that is still the last line
    /// a second later is one.
    private static let promptSettle = Duration.seconds(1)

    init(account: RemoteSignInAccount, host: String, launch: TerminalLaunch, setup: ServerSetupModel) {
        self.account = account
        self.host = host
        self.launch = launch
        self.setup = setup
    }

    var isRunning: Bool { terminal?.isRunning == true }

    /// Starts the command, or starts it again after a failure, in a fresh pty.
    func start() {
        terminal?.stop()
        exit = nil
        step = .connecting
        verdict = .pending
        isComplete = false
        hasOpenedLink = false
        hasRepliedAutomatically = false
        unrecognisedSince = nil
        pastedCode = ""
        showsTerminal = false

        let session = LoginTerminalSession(launch: launch, label: "\(account.title) on \(host)") { [weak self] exit in
            self?.finished(exit)
        }
        // Sized before it starts, because the terminal is folded away and may never be on screen.
        // A pty opened with no frame would give the CLI a width to wrap its address against that
        // bears no relation to the panel it is later shown in.
        session.terminal.frame = NSRect(x: 0, y: 0, width: 620, height: 240)
        session.terminal.onOutput = { [weak self] in self?.scheduleRead() }
        terminal = session
        session.start()
    }

    func stop() {
        terminal?.stop()
    }

    /// Opens the step's page in this Mac's browser. For a device code it copies the code first,
    /// because the page asks for it straight away, and presses Return for gh, which waits on one
    /// before it starts polling.
    func openLink() {
        guard let link = step.link else { return }
        if case .enterCode(let code, _, let needsReturn) = step {
            Clipboard.copy(code)
            if needsReturn { terminal?.terminal.send(txt: "\r") }
        }
        NSWorkspace.shared.open(link)
        hasOpenedLink = true
    }

    /// Types the code copied back from the browser at Claude Code's prompt.
    func submitCode() {
        let code = pastedCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, case .pasteCode = step, let terminal else { return }
        // A carriage return, which is what Return sends down a pty.
        terminal.terminal.send(txt: code + "\r")
        pastedCode = ""
        step = .confirming
        scheduleRead()
    }

    private func scheduleRead(after delay: Duration? = nil) {
        guard !isReadScheduled else { return }
        isReadScheduled = true
        let wait = delay ?? Self.readDelay
        Task { [weak self] in
            try? await Task.sleep(for: wait)
            self?.read()
        }
    }

    private func read() {
        isReadScheduled = false
        guard let terminal else { return }
        let reading = RemoteSignInReading(account: account, output: terminal.terminal.renderedOutput(lines: 400))

        if let reply = reading.automaticReply, !hasRepliedAutomatically, exit == nil {
            hasRepliedAutomatically = true
            terminal.terminal.send(txt: reply)
        }

        let next = RemoteSignInStep.decide(account: account, reading: reading, exit: exit)
        if next == .unrecognised, step != .unrecognised {
            let now = ContinuousClock.now
            guard let since = unrecognisedSince, now - since >= Self.promptSettle else {
                if unrecognisedSince == nil { unrecognisedSince = now }
                scheduleRead(after: Self.promptSettle)
                return
            }
        } else if next != .unrecognised {
            unrecognisedSince = nil
        }
        step = next
        if next.needsTerminal { showsTerminal = true }
    }

    private func finished(_ exit: TerminalExit) {
        self.exit = exit
        read()
        guard step == .finished else { return }
        verdict = .checking
        Task { await verify() }
    }

    private func verify() async {
        await setup.refreshAccounts()
        guard verdict == .checking else { return }
        guard setup.isAuthenticated(account) else {
            verdict = .stillSignedOut
            showsTerminal = true
            return
        }
        verdict = .signedIn
        try? await Task.sleep(for: Self.successPause)
        if verdict == .signedIn { isComplete = true }
    }
}
