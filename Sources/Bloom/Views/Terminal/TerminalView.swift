import SwiftUI
import AppKit
import SwiftTerm
import BloomCore

/// Everything needed to fork a shell: which one, where, and with what in its environment. Kept as
/// a value so the decision is made once, by whoever knows the workspace, rather than by the view.
struct TerminalLaunch: Sendable, Hashable {
    var executable: String
    /// argv[0]. A leading dash is what tells zsh and bash to behave as a login shell.
    var execName: String
    var arguments: [String]
    /// KEY=VALUE pairs, the shape SwiftTerm wants.
    var environment: [String]
    var directory: String

    /// The user's login shell, with the app's augmented PATH and the workspace variables layered
    /// on top. A GUI-launched app inherits a nearly empty PATH, so without `Shell.environment()`
    /// the shell would not find homebrew, mise, nvm or anything else the user installed.
    static func loginShell(directory: String, extra: [String: String]) -> TerminalLaunch {
        let shell = LoginShell.path()

        var variables = Shell.environment(extra: extra)
        variables["TERM"] = "xterm-256color"
        variables["COLORTERM"] = "truecolor"
        variables["TERM_PROGRAM"] = "Bloom"
        if variables["LANG"] == nil { variables["LANG"] = "en_US.UTF-8" }

        return TerminalLaunch(
            executable: shell,
            // From the shell that will actually run, not from `SHELL`. This used to test the
            // path, fall back, and then name the shell from the value it had just rejected.
            execName: LoginShell.argumentZero(for: shell),
            arguments: [],
            environment: variables.map { "\($0.key)=\($0.value)" }.sorted(),
            directory: directory
        )
    }

    /// The same shell, but held by a tmux session instead of by this app, so it survives a quit.
    ///
    /// The pty child is a tmux *client*. Killing it, which is what quitting does, detaches rather
    /// than terminates: the server is daemonised into its own session and keeps the shell and
    /// everything the user started in it.
    ///
    /// The workspace variables are handed to tmux with `-e` rather than left in this process's
    /// environment, because the server is shared by every pane and outlives any one of them. What
    /// this process passes only reaches the server the first time one is started.
    static func tmux(
        command: TmuxCommand,
        session: String,
        directory: String,
        extra: [String: String]
    ) -> TerminalLaunch {
        var variables = Shell.environment()
        variables["TERM"] = "xterm-256color"
        variables["COLORTERM"] = "truecolor"
        variables["TERM_PROGRAM"] = "Bloom"
        if variables["LANG"] == nil { variables["LANG"] = "en_US.UTF-8" }

        var sessionVariables = extra
        sessionVariables["COLORTERM"] = "truecolor"
        sessionVariables["TERM_PROGRAM"] = "Bloom"

        return TerminalLaunch(
            executable: command.executable,
            execName: "tmux",
            arguments: command.attachOrCreate(
                session: session, directory: directory, environment: sessionVariables
            ),
            environment: variables.map { "\($0.key)=\($0.value)" }.sorted(),
            directory: directory
        )
    }
}

/// A live shell in a pseudo terminal.
///
/// This is a class rather than something SwiftUI rebuilds because the pty and its scrollback live
/// inside it. Recreating the view would kill the user's shell, so instances are owned by
/// `TerminalSessionStore` and handed to SwiftUI as-is.
final class BloomTerminalView: LocalProcessTerminalView {
    private(set) var hasExited = false

    /// Set when Bloom is the one ending this shell rather than the shell ending by itself. The two
    /// have to be told apart: closing a tab, archiving a workspace and quitting all kill shells,
    /// and a terminal that reported those the way it reports a user typing `exit` would announce a
    /// teardown in a pane nobody can see any more, and ask for a close that is already happening.
    private var isStopping = false

    /// Called when this shell takes the keyboard, so the tab it is a pane of can dim the others.
    var onFocus: (@MainActor () -> Void)?

    /// Called when the child process ends by itself, with the end already decoded. Whoever owns the
    /// pane decides what that means: `TerminalSplitView` closes the pane on a clean exit, and the
    /// sign-in sheet reads it as its command having finished.
    var onExit: (@MainActor (TerminalExit) -> Void)?

    /// The split commands, answered by whatever owns this pane. It returns false for a command it
    /// cannot serve, such as an arrow with no pane beyond it, which is what lets the same
    /// keystroke fall through to the app menu instead of being swallowed.
    var onCommand: (@MainActor (TerminalPaneCommand) -> Bool)?

    /// Asked when AppKit wants a contextual menu. `.contextMenu` in SwiftUI never fires here:
    /// SwiftTerm's view consumes the right mouse event before SwiftUI sees it.
    var onContextMenu: (@MainActor () -> NSMenu?)?

    private let processObserver = TerminalProcessObserver()

    private var terminalScheme: TerminalScheme = .bloom
    private var typography = ThemeTypography()
    private var usesGhosttyTheme = false

    /// What is on screen, which is what the two shortcuts step from. Readable from outside because
    /// the View menu steps from it too, and stepping from the stored size instead would make the
    /// menu item and the keystroke disagree on any terminal following Ghostty.
    ///
    /// Ghostty's `font-size` when the typography names none, so a terminal opens at the size the
    /// user reads everywhere else rather than at Bloom's own body size.
    var fontSize: CGFloat {
        CGFloat(typography.fontSize ?? ghostty?.fontSize ?? Double(TerminalTextSize.systemDefault))
    }

    func updateTheme() {
        let preference = ColourThemePreference.shared
        let scheme = preference.terminalScheme
        let typography = preference.terminalTypography
        let followsGhostty = preference.followsGhostty
        guard terminalScheme != scheme || self.typography != typography || usesGhosttyTheme != followsGhostty else { return }
        terminalScheme = scheme
        self.typography = typography
        usesGhosttyTheme = followsGhostty
        applyFont()
        applyAppearanceColors()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        processObserver.owner = self
        processDelegate = processObserver
        updateTheme()
        applyFont()
        applyAppearanceColors()
    }

    private func applyFont() {
        let desired = terminalFont(size: fontSize)
        if font != desired { font = desired }
        let spacing = CGFloat(typography.lineHeight ?? 1)
        if lineSpacing != spacing { lineSpacing = spacing }
    }

    /// Ghostty's `font-family` when there is one and it is installed, the monospaced system font
    /// otherwise.
    private func terminalFont(size: CGFloat) -> NSFont {
        TerminalGhostty.font(family: typography.fontFamily ?? ghostty?.fontFamily, size: size)
    }

    // MARK: - Process

    func start(_ launch: TerminalLaunch) {
        guard !process.running else { return }
        hasExited = false
        startProcess(
            executable: launch.executable,
            args: launch.arguments,
            environment: launch.environment,
            execName: launch.execName,
            currentDirectory: launch.directory
        )
    }

    /// Tells the terminal that Bloom is about to end this shell, ahead of whatever signal does it.
    /// Separate from `shutdown` because the store signals the whole process group first, and
    /// because archiving kills a tmux session out from under a pane this app never signals at all.
    func willStop() {
        isStopping = true
    }

    func shutdown() {
        isStopping = true
        guard process.running else { return }
        terminate()
    }

    fileprivate func handleProcessExit(_ status: Int32?) {
        guard !hasExited else { return }
        hasExited = true
        // Bloom ended this one, so there is nobody to tell and nothing to close.
        guard !isStopping else { return }

        let exit = TerminalExit(waitStatus: status)
        // A clean exit closes the pane, and a line printed into a pane that is going away is a
        // line nobody reads. Everything else stays on screen with its reason under it.
        if !exit.closesPane {
            // SGR 2 is faint, which is exactly the dimmed treatment this line wants.
            feed(text: "\r\n\u{1b}[2m\(exit.paneMessage)\u{1b}[0m\r\n")
        }
        onExit?(exit)
    }

    /// A click is the one way a pane takes the keyboard that the tab does not already know about,
    /// so it is where the tab is told. `becomeFirstResponder` would be the truer hook, but
    /// SwiftTerm overrides it as `public` rather than `open`, which puts it out of reach here.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onFocus?()

    }

    /// A right click is also a claim on the keyboard: acting on a menu item means acting on this
    /// pane, so it becomes the focused one before the menu is even drawn.
    override func menu(for event: NSEvent) -> NSMenu? {
        onFocus?()
        return onContextMenu?() ?? super.menu(for: event)

    }

    /// The pane's own menu, put on screen here rather than by AppKit's contextual menu machinery.
    ///
    /// That machinery is where AutoFill came from. `NSView.rightMouseDown` ends in
    /// `NSMenu.popUpContextMenu(_:with:for:)`, and that call asks the view's `NSTextInputContext`
    /// what the text input system wants to add and merges the answer into the menu WINDOW rather
    /// than into the `NSMenu` it was handed. `TerminalPaneMenu.make` returns four items and five
    /// were drawn; the fifth is in `items` at no point, not in `menuNeedsUpdate`, not in
    /// `willOpenMenu` after `super`, not once tracking has ended. So nothing reachable through
    /// `NSMenu` could have removed it, and the title is localised, so matching on it would have
    /// been a fix that worked on this machine and quietly failed on somebody else's. Measured on
    /// macOS 27, against SwiftTerm's view and against a plain `NSTextView`, which grows the same
    /// item from the same place.
    ///
    /// `NSMenu.popUp(positioning:at:in:)` is the same menu without that merge, and it is the only
    /// lever here that is neither a title match nor private API. The input context itself is
    /// untouched, so marked text, dead keys and every input method still work; copy, paste and
    /// select all are Edit menu commands answered by SwiftTerm and never came through here at all.
    ///
    /// A view with no menu of its own falls back to AppKit, so the sign-in sheet's terminal, which
    /// sets no `onContextMenu`, still gets whatever AppKit would have given it.
    override func rightMouseDown(with event: NSEvent) {
        guard onContextMenu != nil, let menu = menu(for: event) else {
            super.rightMouseDown(with: event)
            return
        }
        menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
    }

    /// Keystrokes on their way to the shell, swallowed once it is gone.
    ///
    /// Return used to restart the shell here, and the pane said so. That state is what a terminal
    /// tab must never be left in: a pane offering to fork a second shell is not a terminal, it is
    /// a prompt about one. A pane that survives its shell now survives it read-only, holding the
    /// output that explains the exit until the user closes the tab, which is what every other
    /// terminal on this Mac does.
    override func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        guard !hasExited else { return }
        super.send(source: source, data: data)
    }

    // MARK: - Appearance

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyFont()
        applyAppearanceColors()
    }

    /// The user's Ghostty configuration, when they have one and have not turned this off.
    ///
    /// Read through `effectiveAppearance` rather than the app's, because a `theme = light:…,dark:…`
    /// has to follow the window the terminal is actually in.
    private var ghostty: GhosttyTheme? {
        usesGhosttyTheme ? TerminalGhostty.theme(for: effectiveAppearance) : nil
    }

    /// SwiftTerm ships a palette that looks nothing like the rest of Bloom, so both the sixteen
    /// ANSI slots and the default foreground and background are replaced here.
    func applyAppearanceColors() {
        let fallback = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? terminalScheme.dark : terminalScheme.light
        let theme = ghostty ?? fallback
        installColors(theme.ansiColors().map(SwiftTerm.Color.init))
        nativeForegroundColor = (theme.foreground ?? fallback.foreground).map(NSColor.init) ?? .labelColor
        nativeBackgroundColor = (theme.background ?? fallback.background).map(NSColor.init) ?? .textBackgroundColor
        let background = nativeBackgroundColor.usingColorSpace(.deviceRGB)
        for scroller in subviews.compactMap({ $0 as? NSScroller }) {
            scroller.knobStyle = (background?.brightnessComponent ?? 1) < 0.5 ? .light : .dark
        }
        // Ghostty falls back to the foreground for the cursor, and to the system for a selection it
        // was never told about.
        caretColor = theme.cursorColor.map(NSColor.init) ?? nativeForegroundColor
        caretTextColor = theme.cursorTextColor.map(NSColor.init)
        selectedTextBackgroundColor = theme.selectionBackground.map(NSColor.init) ?? .selectedTextBackgroundColor
        selectedTextForegroundColor = theme.selectionForeground.map(NSColor.init) ?? nativeForegroundColor
        needsDisplay = true
    }

    // MARK: - Keyboard

    /// The app menu may or may not claim these, so they are handled here too. `performKeyEquivalent`
    /// runs before `keyDown`, which SwiftTerm owns and does not let us override from outside.
    ///
    /// This view beats the menu bar, which was measured rather than assumed: with the keyboard in a
    /// terminal, Cmd+Plus, Cmd+Minus and Cmd+0 all land here and the View menu's Zoom items never
    /// fire. `NSApplication` offers a key equivalent to the key window's view tree first and only
    /// then to the main menu, so a shortcut a focused view claims is a shortcut the menu never sees.
    ///
    /// The two are made to agree rather than left to that. `TextZoom` resolves the same three keys
    /// by walking up from first responder, so whichever route runs acts on the same terminal. The
    /// walk is deliberately the looser test of the two: the guard below wants first responder to be
    /// this exact view, and a click that leaves it on the terminal's own scroll bar hands the key
    /// to the menu instead. That case was seen, and it grows the terminal either way.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.control),
              window?.firstResponder === self,
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }

        // Splitting comes first, because Cmd+W here means the pane and not the session the app
        // menu would close, and because the menu only ever sees a key this hands back.
        if let command = TerminalPaneCommand(key: key, modifiers: event.modifierFlags),
           onCommand?(command) == true {
            return true
        }

        // Everything below is a plain Command shortcut, so Option and Shift have to be checked
        // rather than ignored. This view is offered every key equivalent before the menu bar is,
        // and matching on the character alone meant a focused terminal quietly ate shortcuts that
        // belong to the app and that its own menus advertise: Cmd+Option+K, which steps back
        // through a review's changed files, cleared the scrollback instead, and Shift+Cmd+C, which
        // the Workspace menu shows as Copy Branch Name, copied the terminal's selection. Cmd+Plus
        // keeps Shift, because that is how the character is typed at all.
        let shift = event.modifierFlags.contains(.shift)
        guard !event.modifierFlags.contains(.option) else {
            return super.performKeyEquivalent(with: event)
        }

        // Claim this before Archive Workspace's menu equivalent. Sending the original event
        // through the terminal keeps enhanced keyboard protocols intact; legacy shells need
        // Ctrl+U because SwiftTerm does not handle AppKit's deleteToBeginningOfLine selector.
        if let input = TerminalEditingShortcut.input(
            key: key,
            isPlainCommand: !shift,
            usesEnhancedKeyboard: !getTerminal().keyboardEnhancementFlags.isEmpty
        ) {
            switch input {
            case .text(let text): send(txt: text)
            case .keyEvent: keyDown(with: event)
            }
            return true
        }

        switch key {
        case "k" where !shift:
            clearScreen()
        case "c" where !shift:
            copy(self)
        case "v" where !shift:
            paste(self)
        // Written to the preference rather than to this view, so the size survives the shell it
        // was set in and every other open terminal follows it.
        case "+", "=":
            TerminalTextSize.adjust(from: fontSize, by: TerminalTextSize.step)
        case "-":
            TerminalTextSize.adjust(from: fontSize, by: -TerminalTextSize.step)
        case "0":
            TerminalTextSize.override = nil
        default:
            return super.performKeyEquivalent(with: event)
        }
        return true
    }

    /// Screen and scrollback both go, then a form feed nudges the shell into redrawing its prompt
    /// so the user is not left staring at an empty rectangle.
    func clearScreen() {
        getTerminal().clearScrollback()
        feed(text: "\u{1b}[3J\u{1b}[H\u{1b}[2J")
        if process.running { send(txt: "\u{0C}") }
        needsDisplay = true
    }
}

/// SwiftTerm's `LocalProcessTerminalView` already implements several of the delegate methods on
/// itself, and they are `public` rather than `open`, so a subclass outside the module cannot be
/// its own `processDelegate` without recursing. A separate object sidesteps that entirely.
private final class TerminalProcessObserver: LocalProcessTerminalViewDelegate {
    weak var owner: BloomTerminalView?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}

    func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {
        // Read the terminal out first: it is a main-actor class and so Sendable, while this
        // observer is not, and capturing the observer itself would send a non-Sendable self.
        let terminal = owner
        // SwiftTerm's LocalProcess dispatches on DispatchQueue.main unless told otherwise, and
        // LocalProcessTerminalView never tells it otherwise. That is a reading of SwiftTerm
        // 1.18.0's source rather than a guarantee it writes down, and the package is pinned
        // open-ended, so `hopToMain` checks instead of assuming. See `OnMain`: being wrong here
        // is a fatal trap on a terminal exiting, not a wrong pixel.
        hopToMain {
            terminal?.handleProcessExit(exitCode)
        }
    }
}

/// A plain container so SwiftUI can attach and detach a long-lived terminal without the terminal
/// ever being deallocated, and so the pty follows the view size on every layout pass.
final class TerminalHostView: NSView {
    private weak var terminal: BloomTerminalView?

    /// Whether this is the pane the tab says holds the keyboard. Only that one reaches for it when
    /// the tab appears: four shells all grabbing first responder as they are drawn would leave the
    /// keyboard wherever the last layout pass happened to end.
    var isFocusedPane = true

    /// Changes when the user moves focus with the keyboard, and is compared rather than acted on,
    /// because `updateNSView` also runs for redraws that have nothing to do with focus. A pane that
    /// took first responder on every one of those would pull the caret out of the composer.
    var focusRequest = 0 {
        didSet {
            guard oldValue != focusRequest, isFocusedPane else { return }
            takeKeyboard()
        }
    }

    func attach(_ view: BloomTerminalView) {
        guard terminal !== view || view.superview !== self else { return }
        terminal?.removeFromSuperview()
        view.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        terminal = view
        needsLayout = true
    }

    override func layout() {
        super.layout()
        terminal?.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, isFocusedPane else { return }
        let previousResponder = window.firstResponder
        // A later click wins over a focus request queued while this terminal was attaching.
        DispatchQueue.main.async { [weak self, weak window, weak previousResponder] in
            guard let self, let window, self.window === window,
                  window.firstResponder === previousResponder else { return }
            self.takeKeyboard()
        }
    }

    private func takeKeyboard() {
        guard isFocusedPane, let terminal, let window, window.firstResponder !== terminal,
              AutomaticFocus.mayUpdateResponder(applicationIsActive: NSApp.isActive,
                                                windowIsKey: window.isKeyWindow,
                                                windowIsVisible: window.isVisible) else { return }
        window.makeFirstResponder(terminal)
    }
}

/// The SwiftUI face of a terminal tab. It owns nothing: the live view comes from
/// `TerminalSessionStore`, which is what keeps a shell running across tab and workspace switches.
struct TerminalView: NSViewRepresentable {
    var tab: TerminalTab
    var workspace: Workspace
    var repo: Repo?
    var port: Int
    /// The folder this pane's shell starts in, empty for the worktree root. Every pane of a tab
    /// gets the tab's, so splitting a terminal opened on a folder stays in that folder, which is
    /// what splitting does in every other terminal.
    var directory: String = ""

    /// Split panes only. A tab holding one terminal is always its own focused pane and never moves
    /// the keyboard, so it leaves all four of these alone.
    var isFocusedPane = true
    var focusRequest = 0
    var onFocus: (@MainActor () -> Void)?
    var onCommand: (@MainActor (TerminalPaneCommand) -> Bool)?
    /// The shell in this pane ended by itself. Set by every pane, split or not, because a tab
    /// nobody split is still one pane and its shell still ends.
    var onExit: (@MainActor (TerminalExit) -> Void)?
    var onContextMenu: (@MainActor () -> NSMenu?)?

    func makeNSView(context: Context) -> TerminalHostView {
        let host = TerminalHostView()
        configure(host)
        return host
    }

    func updateNSView(_ nsView: TerminalHostView, context: Context) {
        configure(nsView)
    }

    private func configure(_ host: TerminalHostView) {
        let session = self.session
        host.attach(session)
        session.updateTheme()
        session.onFocus = onFocus
        session.onCommand = onCommand
        session.onContextMenu = onContextMenu
        session.onExit = onExit
        // Before the request, whose `didSet` reads it.
        host.isFocusedPane = isFocusedPane
        host.focusRequest = focusRequest
    }

    @MainActor private var session: BloomTerminalView {
        TerminalSessionStore.shared.terminal(
            for: tab, workspace: workspace, repo: repo, port: port, directory: directory
        )
    }
}
