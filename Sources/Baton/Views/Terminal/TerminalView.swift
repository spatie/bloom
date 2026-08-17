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

    private let processObserver = TerminalProcessObserver()

    /// Kept separate from `font` so Cmd+Plus and Cmd+Minus have something to step.
    private var fontSize: CGFloat = 12 {
        didSet { font = Self.monospacedFont(size: fontSize) }
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
        font = Self.monospacedFont(size: fontSize)
        applyAppearanceColors()
    }

    static func monospacedFont(size: CGFloat) -> NSFont {
        NSFont(name: "SFMono-Regular", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
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

    /// SwiftTerm ships a palette that looks nothing like the rest of Baton, so both the sixteen
    /// ANSI slots and the default foreground and background are replaced here.
    func applyAppearanceColors() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

        installColors(isDark ? Self.darkAnsi : Self.lightAnsi)
        nativeForegroundColor = NSColor(hex: isDark ? 0xEDEDEF : 0x1C1C1E)
        nativeBackgroundColor = NSColor(hex: isDark ? 0x1B1B1D : 0xF4F4F2)
        caretColor = NSColor(hex: isDark ? 0x5B8DEF : 0x2F6FED)
        selectedTextBackgroundColor = NSColor(hex: isDark ? 0xFFFFFF26 : 0x00000020)
        needsDisplay = true
    }

    private static let darkAnsi: [SwiftTerm.Color] = [
        SwiftTerm.Color(red8: 0x2A, green8: 0x2A, blue8: 0x2E),
        SwiftTerm.Color(red8: 0xF0, green8: 0x6A, blue8: 0x6A),
        SwiftTerm.Color(red8: 0x3F, green8: 0xBF, blue8: 0x7F),
        SwiftTerm.Color(red8: 0xE0, green8: 0xA9, blue8: 0x3B),
        SwiftTerm.Color(red8: 0x5B, green8: 0x8D, blue8: 0xEF),
        SwiftTerm.Color(red8: 0xC7, green8: 0x92, blue8: 0xEA),
        SwiftTerm.Color(red8: 0x5B, green8: 0xC8, blue8: 0xDB),
        SwiftTerm.Color(red8: 0xC8, green8: 0xC8, blue8: 0xCE),
        SwiftTerm.Color(red8: 0x6E, green8: 0x6E, blue8: 0x76),
        SwiftTerm.Color(red8: 0xFF, green8: 0x8A, blue8: 0x8A),
        SwiftTerm.Color(red8: 0x64, green8: 0xD9, blue8: 0x9B),
        SwiftTerm.Color(red8: 0xF0, green8: 0xC4, blue8: 0x63),
        SwiftTerm.Color(red8: 0x84, green8: 0xAA, blue8: 0xF5),
        SwiftTerm.Color(red8: 0xDD, green8: 0xB0, blue8: 0xF5),
        SwiftTerm.Color(red8: 0x84, green8: 0xDC, blue8: 0xE9),
        SwiftTerm.Color(red8: 0xED, green8: 0xED, blue8: 0xEF),
    ]

    private static let lightAnsi: [SwiftTerm.Color] = [
        SwiftTerm.Color(red8: 0x1C, green8: 0x1C, blue8: 0x1E),
        SwiftTerm.Color(red8: 0xC0, green8: 0x30, blue8: 0x30),
        SwiftTerm.Color(red8: 0x1A, green8: 0x7F, blue8: 0x4B),
        SwiftTerm.Color(red8: 0xB0, green8: 0x79, blue8: 0x08),
        SwiftTerm.Color(red8: 0x2F, green8: 0x6F, blue8: 0xED),
        SwiftTerm.Color(red8: 0x9B, green8: 0x23, blue8: 0x93),
        SwiftTerm.Color(red8: 0x0B, green8: 0x72, blue8: 0x85),
        SwiftTerm.Color(red8: 0x9A, green8: 0x9A, blue8: 0xA0),
        SwiftTerm.Color(red8: 0x6B, green8: 0x6B, blue8: 0x70),
        SwiftTerm.Color(red8: 0xD8, green8: 0x4A, blue8: 0x4A),
        SwiftTerm.Color(red8: 0x2A, green8: 0x9D, blue8: 0x63),
        SwiftTerm.Color(red8: 0xC7, green8: 0x92, blue8: 0x12),
        SwiftTerm.Color(red8: 0x4A, green8: 0x85, blue8: 0xF0),
        SwiftTerm.Color(red8: 0xB4, green8: 0x3C, blue8: 0xAC),
        SwiftTerm.Color(red8: 0x1A, green8: 0x8C, blue8: 0xA0),
        SwiftTerm.Color(red8: 0x33, green8: 0x33, blue8: 0x38),
    ]

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

        switch key {
        case "k":
            clearScreen()
        case "c":
            copy(self)
        case "v":
            paste(self)
        case "+", "=":
            fontSize = min(fontSize + 1, 32)
        case "-":
            fontSize = max(fontSize - 1, 8)
        case "0":
            fontSize = 12
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
        // SwiftTerm's LocalProcess dispatches on DispatchQueue.main unless told otherwise, and
        // LocalProcessTerminalView never tells it otherwise.
        MainActor.assumeIsolated {
            owner?.handleProcessExit(exitCode)
        }
    }
}

/// A plain container so SwiftUI can attach and detach a long-lived terminal without the terminal
/// ever being deallocated, and so the pty follows the view size on every layout pass.
final class TerminalHostView: NSView {
    private weak var terminal: BatonTerminalView?

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
        guard let terminal, window != nil else { return }
        // Give the shell the keyboard as soon as the tab is shown.
        DispatchQueue.main.async { [weak self] in
            guard self?.window != nil else { return }
            terminal.window?.makeFirstResponder(terminal)
        }
    }
}

/// The SwiftUI face of a terminal tab. It owns nothing: the live view comes from
/// `TerminalSessionStore`, which is what keeps a shell running across tab and workspace switches.
struct TerminalView: NSViewRepresentable {
    var tab: TerminalTab
    var workspace: Workspace
    var repo: Repo?
    var port: Int

    func makeNSView(context: Context) -> TerminalHostView {
        let host = TerminalHostView()
        host.attach(session)
        return host
    }

    func updateNSView(_ nsView: TerminalHostView, context: Context) {
        nsView.attach(session)
    }

    @MainActor private var session: BatonTerminalView {
        TerminalSessionStore.shared.terminal(
            for: tab, workspace: workspace, repo: repo, port: port
        )
    }
}
