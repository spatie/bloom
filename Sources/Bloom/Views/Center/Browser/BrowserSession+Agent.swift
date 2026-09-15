import AppKit
import WebKit
import BloomCore

/// The half of a browser session an agent drives: the outline, the click, the fill, the key, the
/// wait, the console and the requests.
///
/// Every script is `BrowserAgentScript` or `BrowserConsoleScript` in the core, and every rule
/// about what an answer means is `BrowserInteractionReport`. What is here is the one thing neither
/// can do, which is hand a script to WebKit.
///
/// All of them go through `callAsyncJavaScript` with arguments, never `evaluateJavaScript` with
/// text, so what a caller wrote reaches the page as a value and never as source. The head of
/// `BrowserPaneCommand` argues why that line is the one that matters.
extension BrowserSession {
    /// Bloom's own content world. See `BrowserAgentScript` for why the scripts are not run in the
    /// page's.
    private static var agentWorld: WKContentWorld { .world(name: BrowserAgentScript.worldName) }

    /// The size a pane nobody has drawn is laid out at: a laptop's browser window, which is what
    /// most responsive layouts are designed around.
    private static let offscreenSize = CGSize(width: 1_280, height: 800)

    /// Gives a web view that has never been on screen a size to lay the page out at.
    ///
    /// **This is what made a pane an agent opened in the background unreadable.** A session is
    /// created by the pane that draws it, so a tab opened behind the one in front had no web view
    /// at all, and every tool answered that nobody had opened it. Creating the session is half the
    /// fix. The other half is here: a web view made outside a window is zero points wide, and a
    /// page laid out at zero points is a snapshot of nothing. Measured on macOS 27 in a bare
    /// process: a `WKWebView` given a frame and never put in a window loads, runs script and
    /// snapshots the page as drawn, so no offscreen window is needed.
    ///
    /// A view that has been drawn keeps the frame its pane gave it, which is the size the person
    /// last saw it at, so only an empty frame is touched. The pane replaces it on first draw.
    func prepareForAgent() {
        guard webView.window == nil, webView.bounds.isEmpty else { return }
        pageView.frame = CGRect(origin: .zero, size: Self.offscreenSize)
        webView.frame = pageView.bounds
    }

    /// Waits, a little, for a page that is still loading.
    ///
    /// Ten seconds and then whatever is there, because a dev server that never finishes a load
    /// (a long poll, a stuck asset) must not hang the tool call, and a picture of a half-drawn
    /// page is still an answer.
    func settle(within milliseconds: Int = 10_000) async {
        let deadline = ContinuousClock.now + .milliseconds(milliseconds)
        while webView.isLoading, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - Reading and acting

    func outline() async throws -> BrowserPageOutline {
        let value = try await webView.callAsyncJavaScript(
            BrowserAgentScript.snapshot,
            arguments: ["limit": BrowserPageOutline.limit, "chars": BrowserPageOutline.nameLimit],
            contentWorld: Self.agentWorld
        )
        guard let outline = BrowserPageOutline.read(value) else { throw BrowserScriptFailure() }
        return outline
    }

    func click(_ ref: BrowserElementRef) async throws -> [String] {
        try await words(BrowserAgentScript.click, ["ref": ref.number])
    }

    func fill(_ ref: BrowserElementRef, with text: String) async throws -> [String] {
        try await words(BrowserAgentScript.fill, ["ref": ref.number, "text": text])
    }

    func press(_ key: BrowserKey, on ref: BrowserElementRef?) async throws -> [String] {
        try await words(BrowserAgentScript.press, [
            "ref": ref?.number ?? 0,
            "key": key.key,
            "code": key.code,
            "keyCode": key.keyCode,
            "shift": key.modifiers.contains(.shift),
            "control": key.modifiers.contains(.control),
            "alt": key.modifiers.contains(.alt),
            "meta": key.modifiers.contains(.meta),
            "character": key.isCharacter,
        ])
    }

    /// Polls rather than waiting inside the page. See `BrowserAgentScript.check` for why.
    func wait(_ wait: BrowserWait) async -> BrowserWait.Outcome {
        let start = ContinuousClock.now
        let limit = Duration.milliseconds(wait.milliseconds)
        while true {
            let elapsed = ContinuousClock.now - start
            let milliseconds = Int(elapsed.components.seconds * 1_000)
                + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)

            switch await isMet(wait.condition) {
            case .some(true): return .met(milliseconds)
            case .none: return .badSelector
            case .some(false): break
            }
            guard elapsed < limit else { return .timedOut(milliseconds) }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    /// True, false, or nil for a selector the page could not parse.
    private func isMet(_ condition: BrowserWait.Condition) async -> Bool? {
        switch condition {
        case .load:
            return !webView.isLoading
        case .url(let part):
            return displayAddress.contains(part)
        case .selector(let value), .text(let value):
            let kind = if case .selector = condition { "selector" } else { "text" }
            // A throw is a page that navigated under the check, which is not the thing being
            // waited for and not a reason to stop waiting either.
            let answer = try? await webView.callAsyncJavaScript(
                BrowserAgentScript.check,
                arguments: ["kind": kind, "value": value],
                contentWorld: Self.agentWorld
            )
            switch answer as? String {
            case "yes": return true
            case "bad-selector": return nil
            default: return false
            }
        }
    }

    func network() async throws -> BrowserNetworkLog {
        let value = try await webView.callAsyncJavaScript(
            BrowserAgentScript.network,
            arguments: ["limit": BrowserNetworkLog.limit, "chars": BrowserNetworkLog.addressLimit],
            contentWorld: Self.agentWorld
        )
        guard let log = BrowserNetworkLog.read(value) else { throw BrowserScriptFailure() }
        return log
    }

    /// One of the scripts that answers with a short list of words.
    private func words(_ script: String, _ arguments: [String: Any]) async throws -> [String] {
        let value = try await webView.callAsyncJavaScript(
            script, arguments: arguments, contentWorld: Self.agentWorld
        )
        guard let words = value as? [String] else { throw BrowserScriptFailure() }
        return words
    }

    // MARK: - The console

    /// Starts recording the page's console, once per session. See `BrowserConsoleScript` for why
    /// this waits for the first call rather than running from the moment the pane opens.
    ///
    /// Both halves, because either alone misses something: the user script covers every document
    /// this pane loads from now on, and running the same source straight away covers the one it
    /// is showing. The script guards itself, so a page that gets both runs it once.
    func listenToConsole() {
        guard !consoleLog.isListening else { return }
        consoleLog.isListening = true
        let controller = webView.configuration.userContentController
        controller.add(
            BrowserConsoleListener(owner: self),
            contentWorld: .page,
            name: BrowserConsoleScript.handlerName
        )
        controller.addUserScript(
            WKUserScript(
                source: BrowserConsoleScript.source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .page
            )
        )
        webView.evaluateJavaScript(
            BrowserConsoleScript.source, in: nil, in: .page, completionHandler: nil
        )
    }

    /// Takes the handler off again, which `stop` calls. The user content controller holds its
    /// handlers strongly, and a closed tab should not be keeping a listener alive.
    func stopListeningToConsole() {
        guard consoleLog.isListening else { return }
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
    }
}

/// Where the page's console lines arrive.
///
/// A separate object with a weak link back, for the reason `NavigationObserver` is one: the user
/// content controller holds this strongly, and it belongs to the web view the session owns.
@MainActor
final class BrowserConsoleListener: NSObject, WKScriptMessageHandler {
    private weak var owner: BrowserSession?

    init(owner: BrowserSession) {
        self.owner = owner
    }

    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        guard let owner else { return }
        owner.consoleLog.append(message.body, address: owner.displayAddress)
    }
}
