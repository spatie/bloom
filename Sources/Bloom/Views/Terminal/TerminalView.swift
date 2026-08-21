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
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let name = (shell as NSString).lastPathComponent

        var variables = Shell.environment(extra: extra)
        variables["TERM"] = "xterm-256color"
        variables["COLORTERM"] = "truecolor"
        variables["TERM_PROGRAM"] = "Bloom"
        if variables["LANG"] == nil { variables["LANG"] = "en_US.UTF-8" }

        return TerminalLaunch(
            executable: FileManager.default.isExecutableFile(atPath: shell) ? shell : "/bin/zsh",
            execName: "-" + name,
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

    /// Whether the user's Ghostty configuration is in charge of the font and the colours. Owned by
    /// SwiftUI through `@AppStorage`, so flipping the switch in Settings reaches every live shell.
    var usesGhosttyTheme = true {
        didSet {
            guard usesGhosttyTheme != oldValue else { return }
            applyFont()
            applyAppearanceColors()
        }
    }

    /// The size the user asked for, or nil to follow Ghostty. Owned by SwiftUI through
    /// `@AppStorage`, so the stepper in Settings and a Cmd+Plus pressed in any one shell both reach
    /// every shell in every window rather than only the one with the keyboard.
    var fontSizeOverride: CGFloat? {
        didSet {
            guard fontSizeOverride != oldValue else { return }
            applyFont()
        }
    }

    /// What is on screen, which is what the two shortcuts step from. Readable from outside because
    /// the View menu steps from it too, and stepping from the stored override instead would make
    /// the menu item and the keystroke disagree on any terminal following Ghostty.
    var fontSize: CGFloat { fontSizeOverride ?? defaultFontSize }

    /// Ghostty's `font-size` when it has one, so a terminal opens at the size the user reads
    /// everywhere else rather than at Bloom's own body size.
    private var defaultFontSize: CGFloat {
        ghostty?.fontSize.map { CGFloat($0) } ?? TerminalTextSize.systemDefault
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
        applyFont()
        applyAppearanceColors()
    }

    private func applyFont() {
        font = terminalFont(size: fontSize)
    }

    /// Ghostty's `font-family` when there is one and it is installed, the monospaced system font
    /// otherwise.
    private func terminalFont(size: CGFloat) -> NSFont {
        TerminalGhostty.font(family: ghostty?.fontFamily, size: size)
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
        if let ghostty {
            applyGhosttyColors(ghostty)
        } else {
            applyBloomColors()
        }
        needsDisplay = true
    }

    /// Whatever Ghostty says, with Ghostty's own defaults behind it. Bloom's colours are not
    /// blended in: a terminal that is half the user's theme and half something else reads as a bug,
    /// not as a compromise.
    private func applyGhosttyColors(_ theme: GhosttyTheme) {
        installColors(theme.ansiColors().map(SwiftTerm.Color.init))

        let foreground = theme.foreground.map(NSColor.init)
        let background = theme.background.map(NSColor.init)
        nativeForegroundColor = foreground ?? resolved(Palette.textPrimary).withAlphaComponent(1)
        nativeBackgroundColor = background ?? resolved(Palette.surfaceSunken)
        // Ghostty falls back to the foreground for the cursor, and to the system for a selection it
        // was never told about.
        caretColor = theme.cursorColor.map(NSColor.init) ?? foreground ?? .textInsertionPointColor
        if let cursorText = theme.cursorTextColor {
            caretTextColor = NSColor(cursorText)
        }
        selectedTextBackgroundColor = theme.selectionBackground.map(NSColor.init)
            ?? .selectedTextBackgroundColor
        if let selectionForeground = theme.selectionForeground {
            selectedTextForegroundColor = NSColor(selectionForeground)
        }
    }

    private func applyBloomColors() {
        installColors(ansiColors.map(swiftTermColor))
        // Flattened to opaque. `labelColor` is 85% ink, and a terminal foreground that is not
        // fully opaque prints every character faintly over the panel behind it.
        nativeForegroundColor = resolved(Palette.textPrimary).withAlphaComponent(1)
        // The panel's own surface, so the shell sits on the same colour as the setup and run logs
        // it shares a tab strip with.
        nativeBackgroundColor = resolved(Palette.surfaceSunken)
        caretColor = .textInsertionPointColor
        selectedTextBackgroundColor = .selectedTextBackgroundColor
    }

    /// The sixteen ANSI slots.
    ///
    /// Red, yellow and blue are Bloom's, so a failing test's red in the terminal is the same red
    /// as a failed step everywhere else in the window. Green is NOT, and that is the one to
    /// understand: the app's `positive` is the accent, because the brand ramp says to reuse the
    /// accent rather than invent a green. That is right for a tick beside a passing check, and
    /// wrong here, because ANSI green and ANSI blue are two different slots and a program that
    /// prints both would print them in one colour. So this palette keeps a green of its own,
    /// which is what every terminal theme does.
    ///
    /// The four greyscale slots cannot be the label colours either: those differ from each other
    /// in alpha and in nothing else, and SwiftTerm stores a colour as three opaque bytes.
    /// Dropping the alpha collapsed black, white, bright black and bright white to one identical
    /// value, so black-on-white, which is most of what a Powerline prompt draws, came out as a
    /// solid block with nothing legible inside it.
    ///
    /// They stay ordered dark to light within each appearance, because every program that colours
    /// its own output assumes slot 8 is a lighter slot 0 and slot 15 a lighter slot 7.
    private var ansiColors: [SwiftUI.Color] {
        [
            Self.black,
            Palette.negative,
            Self.green,
            Palette.warning,
            Palette.accent,
            Color(nsColor: .systemPurple),
            Color(nsColor: .systemTeal),
            Self.white,
            Self.brightBlack,
            Palette.negative,
            Self.green,
            Palette.warning,
            Palette.accent,
            Color(nsColor: .systemPurple),
            Color(nsColor: .systemTeal),
            Self.brightWhite,
        ]
    }

    /// ANSI slot 2. Tuned to sit beside `Palette.negative` and `Palette.warning` at the same
    /// volume they do, rather than to be `systemGreen`, which is a step brighter than everything
    /// else this terminal prints.
    private static let green = Palette.dynamic(light: 0x2E7D32, dark: 0x6FCF7B)

    // Per appearance, because the terminal's background follows the system: a fixed #FFFFFF for
    // bright white would be invisible on a light panel, and a fixed #000000 black unreadable on a
    // dark one.
    private static let black = Palette.dynamic(light: 0x000000, dark: 0x1C1C1E)
    private static let brightBlack = Palette.dynamic(light: 0x4D4D4D, dark: 0x636366)
    private static let white = Palette.dynamic(light: 0x8E8E93, dark: 0xAEAEB2)
    private static let brightWhite = Palette.dynamic(light: 0xB0B0B5, dark: 0xFFFFFF)

    private func resolved(_ color: SwiftUI.Color) -> NSColor {
        var native = NSColor(color)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            native = NSColor(color)
        }
        return native
    }

    /// SwiftTerm stores terminal colours as three opaque byte channels, while Bloom keeps dynamic
    /// AppKit colours so they follow appearance, contrast and accent changes. Alpha is lost in the
    /// crossing, which is why nothing in `ansiColors` may rely on it to tell two slots apart.
    private func swiftTermColor(_ color: SwiftUI.Color) -> SwiftTerm.Color {
        let resolved = resolved(color)
        let native = resolved.usingColorSpace(NSColorSpace.deviceRGB) ?? resolved
        return SwiftTerm.Color(
            red8: UInt16(clamping: Int((native.redComponent * 255).rounded())),
            green8: UInt16(clamping: Int((native.greenComponent * 255).rounded())),
            blue8: UInt16(clamping: Int((native.blueComponent * 255).rounded()))
        )
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
        // LocalProcessTerminalView never tells it otherwise.
        MainActor.assumeIsolated {
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
        guard window != nil, isFocusedPane else { return }
        // Give the shell the keyboard as soon as the tab is shown.
        DispatchQueue.main.async { [weak self] in
            self?.takeKeyboard()
        }
    }

    private func takeKeyboard() {
        guard let terminal, let window, window.firstResponder !== terminal else { return }
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

    /// Read here rather than inside the terminal so SwiftUI reruns `updateNSView` when the switch
    /// in Settings moves, which is what pushes the change into a shell that is already running.
    @AppStorage(TerminalGhostty.defaultsKey) private var usesGhosttyTheme = true

    /// Zero is "no override, follow Ghostty". See `TerminalTextSize`.
    @AppStorage(TerminalTextSize.defaultsKey) private var fontSize = 0.0

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
        session.usesGhosttyTheme = usesGhosttyTheme
        session.fontSizeOverride = fontSize > 0 ? CGFloat(fontSize) : nil
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
            for: tab, workspace: workspace, repo: repo, port: port
        )
    }
}
