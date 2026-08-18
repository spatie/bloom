import SwiftUI
import AppKit
import SwiftTerm
import BatonCore

/// Everything needed to fork a shell. Kept as a value so a terminal can relaunch itself with
/// exactly the same shell, directory and environment after the user's shell exits.
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
        variables["TERM_PROGRAM"] = "Baton"
        if variables["LANG"] == nil { variables["LANG"] = "en_US.UTF-8" }

        return TerminalLaunch(
            executable: FileManager.default.isExecutableFile(atPath: shell) ? shell : "/bin/zsh",
            execName: "-" + name,
            arguments: [],
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
final class BatonTerminalView: LocalProcessTerminalView {
    private(set) var launch: TerminalLaunch?
    private(set) var hasExited = false

    /// Called when this shell takes the keyboard, so the tab it is a pane of can dim the others.
    var onFocus: (@MainActor () -> Void)?

    /// The split commands, answered by whatever owns this pane. It returns false for a command it
    /// cannot serve, such as an arrow with no pane beyond it, which is what lets the same
    /// keystroke fall through to the app menu instead of being swallowed.
    var onCommand: (@MainActor (TerminalPaneCommand) -> Bool)?

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

    /// Kept separate from `font` so Cmd+Plus and Cmd+Minus have something to step.
    private var fontSize: CGFloat = NSFont.preferredFont(forTextStyle: .callout).pointSize {
        didSet { font = terminalFont(size: fontSize) }
    }

    /// Ghostty's `font-size` when it has one, so a terminal opens at the size the user reads
    /// everywhere else rather than at Baton's own body size.
    private var defaultFontSize: CGFloat {
        ghostty?.fontSize.map { CGFloat($0) } ?? NSFont.preferredFont(forTextStyle: .callout).pointSize
    }

    /// One point per press, the way every other terminal steps. This used to be `Metrics.hairline`,
    /// which is half a point on a Retina display and a whole one everywhere else, so the shortcut
    /// did almost nothing and did a different almost-nothing depending on the screen.
    private static let fontStep: CGFloat = 1

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

    /// Goes through `fontSize` rather than `font` so Cmd+Plus and Cmd+Minus keep stepping from
    /// the size that is on screen.
    private func applyFont() {
        fontSize = defaultFontSize
    }

    /// Ghostty's `font-family` when there is one and it is installed, the monospaced system font
    /// otherwise.
    private func terminalFont(size: CGFloat) -> NSFont {
        TerminalGhostty.font(family: ghostty?.fontFamily, size: size)
    }

    // MARK: - Process

    func start(_ launch: TerminalLaunch) {
        guard !process.running else { return }
        self.launch = launch
        hasExited = false
        startProcess(
            executable: launch.executable,
            args: launch.arguments,
            environment: launch.environment,
            execName: launch.execName,
            currentDirectory: launch.directory
        )
    }

    func restart() {
        guard let launch else { return }
        getTerminal().resetToInitialState()
        hasExited = false
        start(launch)
    }

    func shutdown() {
        guard process.running else { return }
        terminate()
    }

    fileprivate func handleProcessExit(_ code: Int32?) {
        guard !hasExited else { return }
        hasExited = true
        let suffix = (code ?? 0) == 0 ? "" : " (exit \(code ?? 0))"
        // SGR 2 is faint, which is exactly the dimmed treatment this line wants.
        feed(text: "\r\n\u{1b}[2mProcess finished\(suffix), press Return to restart\u{1b}[0m\r\n")
    }

    /// A click is the one way a pane takes the keyboard that the tab does not already know about,
    /// so it is where the tab is told. `becomeFirstResponder` would be the truer hook, but
    /// SwiftTerm overrides it as `public` rather than `open`, which puts it out of reach here.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onFocus?()
    }

    /// Keystrokes on their way to the shell. When the shell is gone they are swallowed, except a
    /// Return, which is the documented way back to a working terminal.
    override func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        if hasExited {
            if data.contains(0x0D) || data.contains(0x0A) { restart() }
            return
        }
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

    /// SwiftTerm ships a palette that looks nothing like the rest of Baton, so both the sixteen
    /// ANSI slots and the default foreground and background are replaced here.
    func applyAppearanceColors() {
        if let ghostty {
            applyGhosttyColors(ghostty)
        } else {
            applyBatonColors()
        }
        needsDisplay = true
    }

    /// Whatever Ghostty says, with Ghostty's own defaults behind it. Baton's colours are not
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

    private func applyBatonColors() {
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
    /// The six hues stay Baton's, so a red in the terminal is the same red as a failed step
    /// everywhere else in the window. The four greyscale slots cannot be: they were the label
    /// colours, which differ from each other in alpha and in nothing else, and SwiftTerm stores a
    /// colour as three opaque bytes. Dropping the alpha collapsed black, white, bright black and
    /// bright white to one identical value, so black-on-white, which is most of what a Powerline
    /// prompt draws, came out as a solid block with nothing legible inside it.
    ///
    /// They stay ordered dark to light within each appearance, because every program that colours
    /// its own output assumes slot 8 is a lighter slot 0 and slot 15 a lighter slot 7.
    private var ansiColors: [SwiftUI.Color] {
        [
            Self.black,
            Palette.negative,
            Palette.positive,
            Palette.warning,
            Palette.accent,
            Color(nsColor: .systemPurple),
            Color(nsColor: .systemTeal),
            Self.white,
            Self.brightBlack,
            Palette.negative,
            Palette.positive,
            Palette.warning,
            Palette.accent,
            Color(nsColor: .systemPurple),
            Color(nsColor: .systemTeal),
            Self.brightWhite,
        ]
    }

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

    /// SwiftTerm stores terminal colours as three opaque byte channels, while Baton keeps dynamic
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

        switch key {
        case "k":
            clearScreen()
        case "c":
            copy(self)
        case "v":
            paste(self)
        case "+", "=":
            fontSize = min(
                fontSize + Self.fontStep,
                NSFont.preferredFont(forTextStyle: .largeTitle).pointSize
            )
        case "-":
            fontSize = max(
                fontSize - Self.fontStep,
                NSFont.preferredFont(forTextStyle: .caption2).pointSize
            )
        case "0":
            fontSize = defaultFontSize
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
    weak var owner: BatonTerminalView?

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
    private weak var terminal: BatonTerminalView?

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

    func attach(_ view: BatonTerminalView) {
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

    /// Read here rather than inside the terminal so SwiftUI reruns `updateNSView` when the switch
    /// in Settings moves, which is what pushes the change into a shell that is already running.
    @AppStorage(TerminalGhostty.defaultsKey) private var usesGhosttyTheme = true

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
        session.onFocus = onFocus
        session.onCommand = onCommand
        // Before the request, whose `didSet` reads it.
        host.isFocusedPane = isFocusedPane
        host.focusRequest = focusRequest
    }

    @MainActor private var session: BatonTerminalView {
        TerminalSessionStore.shared.terminal(
            for: tab, workspace: workspace, repo: repo, port: port
        )
    }
}
