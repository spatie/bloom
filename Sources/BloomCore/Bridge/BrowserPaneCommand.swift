import Foundation

/// Looking at, and moving, a browser pane the reader has open.
///
/// One value for thirteen tools, for the reason `PaneOrder` is one value for two: every
/// `browser_` tool asks the same question first, which is "which of the reader's browsers do you
/// mean", and a second copy of that answer is how two of them would come to disagree about it.
///
/// ## Why there is no `browser_eval`, and what stands in for it
///
/// The obvious tool is not here. `WKWebView.evaluateJavaScript` with a caller's source would be a
/// complete automation surface in one call, and every browser automation library is that call
/// underneath. It was asked for twice. The first time the answer was the six narrow tools that
/// look at and move a page. The second time, the owner asked for agent-browser's loop in the pane
/// he is looking at: read the page, click, fill in, press a key, wait, and see the console and the
/// network. That loop is here now, and arbitrary script still is not. The reason is what the pane
/// actually is.
///
/// **The pane is the owner's own browser, logged in as him.** The screenshot that started this
/// feature was of his own application with a live session in it. Script running in that page can
/// read everything the session can read, and can act as him: post the form, follow the link that
/// deletes the row, read the token out of `localStorage`, walk the admin area. It is not sandboxed
/// from him in any sense, because it IS him. That is what a session cookie means.
///
/// **And the caller is not necessarily working for him at that moment.** An agent that has read a
/// web page, an issue, a dependency's README or a pull request comment is an agent holding text
/// somebody else wrote, and a model that can be talked into running a script has just handed the
/// author of that text a logged-in browser. This is not hypothetical: the same turn that reads a
/// page is the turn that would call the tool.
///
/// **The gap cannot be closed by asking, because asking is exactly what is hard to read here.**
/// The natural mitigation is to keep it off `BridgeToolApproval.selfApproved` so a person answers
/// for every call, and a permission prompt showing a paragraph of minified JavaScript is a prompt
/// nobody can evaluate. Two lines of it will look reasonable to anybody, including to someone who
/// wrote the tool. A prompt that cannot be read is a prompt that gets approved, and then the whole
/// safety of the feature rests on nobody ever being tired.
///
/// **So the substitute is the named verb rather than the general one.** Every tool here is a
/// thing Bloom does rather than a thing the caller describes: read the toolbar, take a picture,
/// read the text, scroll, reload, go to an address, outline the page, click, fill, press, wait,
/// read the console, list the requests. The scripts are written out in full in
/// `BrowserPageScript` and `BrowserAgentScript`, and what a caller contributes to them is a
/// reference the snapshot issued, a key from a fixed list, or a string handed to
/// `callAsyncJavaScript` as an argument. None of it is ever source.
///
/// **What the verbs buy over eval is a prompt a person can read.** "browser_click ref e7" beside
/// an outline that says e7 is `button "Delete project"` is a question somebody can answer.
/// A paragraph of minified JavaScript is not. The verbs do not make acting in a logged-in page
/// safe, and nothing here pretends they do: a model talked into it can still click the wrong
/// button, which is why none of the acting tools is self-approved and every description says the
/// page is the person's own.
///
/// What is still out of reach should be stated rather than glossed. Events are dispatched by
/// script, so a page that checks `isTrusted` ignores them. There are no uploads, no cross-origin
/// frames, no cookies or storage, and the network list is Resource Timing rather than a network
/// panel. An agent that needs any of those has agent-browser and a Chrome of its own, where nobody
/// is logged in as him.
///
/// If arbitrary script is ever wanted, the shape it has to take is a setting the owner turns on
/// per project, off by default, with the tool refused to every role but `.workspace`, never
/// self-approved, and the script shown in full in the prompt. That is a change to make
/// deliberately and with him asked first, and it is not this one.
public enum BrowserPaneCommand: Sendable, Equatable {
    /// The toolbar's own state for one browser, which is `BrowserPaneReport`.
    case read(Int?)
    case reload(Int?)
    /// Point an existing pane somewhere. Not the same act as `pane_open` with a url, which makes
    /// a new one.
    case go(Int?, String)
    case screenshot(Int?)
    case scroll(Int?, BrowserScroll)
    /// The rendered text of the page, wrapped in `BridgeUntrustedText`.
    case text(Int?)
    /// The page as an outline of elements with references. See `BrowserPageOutline`.
    case snapshot(Int?)
    case click(Int?, BrowserElementRef)
    case fill(Int?, BrowserElementRef, String)
    /// A key, on the referenced element or on whatever has focus.
    case press(Int?, BrowserElementRef?, BrowserKey)
    case wait(Int?, BrowserWait)
    case console(Int?, BrowserConsoleRequest)
    /// The page's requests, kept to those whose address contains the filter.
    case network(Int?, String?)

    /// Whether the command needs the page to have arrived before it is worth doing.
    ///
    /// A pane an agent has only just opened is still fetching, and a screenshot or an outline of
    /// that moment is a blank rectangle that reads as a broken page. Reloading and navigating are
    /// the two that start a load rather than read one, and `browser_wait` is its own judge.
    public var readsPage: Bool {
        switch self {
        case .read, .reload, .go, .wait: false
        default: true
        }
    }

    /// Which tool this command came from.
    ///
    /// Here rather than passed alongside, because the refusals the window gives ("there are three
    /// browsers open, say which") have to name the tool that will be called again, and a name
    /// threaded through a closure is a name that can arrive wrong. The strings themselves are
    /// `BrowserPaneToolName`, which is also what the tools are declared with, so there is one
    /// spelling of each.
    public var toolName: String {
        switch self {
        case .read: BrowserPaneToolName.read
        case .reload: BrowserPaneToolName.reload
        case .go: BrowserPaneToolName.go
        case .screenshot: BrowserPaneToolName.screenshot
        case .scroll: BrowserPaneToolName.scroll
        case .text: BrowserPaneToolName.text
        case .snapshot: BrowserPaneToolName.snapshot
        case .click: BrowserPaneToolName.click
        case .fill: BrowserPaneToolName.fill
        case .press: BrowserPaneToolName.press
        case .wait: BrowserPaneToolName.wait
        case .console: BrowserPaneToolName.console
        case .network: BrowserPaneToolName.network
        }
    }

    /// Which browser the call named, or nothing for "the one that is open".
    public var number: Int? {
        switch self {
        case .read(let number), .reload(let number), .go(let number, _),
             .screenshot(let number), .scroll(let number, _), .text(let number),
             .snapshot(let number), .click(let number, _), .fill(let number, _, _),
             .press(let number, _, _), .wait(let number, _), .console(let number, _),
             .network(let number, _):
            number
        }
    }
}

/// What came of asking the window about, or moving, a browser pane.
///
/// Four cases rather than a `Result`, because two of the answers are not text: a census is
/// rendered by the tool that asked for it, and a screenshot is bytes. `PaneOutcome` next door says
/// the ordinary sentence-or-refusal thing the same way.
public enum BrowserPaneAnswer: Sendable, Equatable {
    /// A sentence for the model, which is what most of these are.
    case told(String)
    /// A structured answer, pretty printed by `BridgeToolResult.json`.
    case reported(JSONValue)
    /// A PNG and the sentence that goes with it.
    case pictured(Data, String)
    case refused(String)
}

/// Reaching a browser pane, which lives in the main-actor UI graph.
///
/// Injected for the reason `PaneOpening` and its three siblings are, and it is one closure for all
/// six tools rather than six: what crosses the line is "do this to that pane", and the app side
/// resolves the pane the same way every time, through `BrowserPaneChoice.choose`.
public typealias BrowserPaneCommanding =
    @Sendable (BrowserPaneCommand, WorkspaceID) async -> BrowserPaneAnswer

/// Which of the reader's browsers a call meant.
///
/// The reading of the number itself is `PaneNumberArgument.browser`, whose head argues why a
/// number is the handle and why a float is refused rather than rounded. That rule was written out
/// here, in `TerminalPaneChoice` and in `WorkspaceTabChoice`, three times over. What is left here
/// is the half that is genuinely this family's: which of the browsers a number names.
public enum BrowserPaneChoice {
    /// Picks the pane a call meant out of the ones the workspace has, or says why it could not.
    ///
    /// **Omitting the number is only allowed when there is one browser.** The tempting default was
    /// "the one in front", and it is wrong here in a way it is not wrong for `pane_close`: closing
    /// the focused pane is a gesture the reader can see the result of immediately, while reading
    /// or driving the wrong page is a mistake whose result is a wrong answer that looks right. A
    /// caller that has not said which of three browsers it means has not decided, and the refusal
    /// lists them so that its next call can.
    public static func choose(
        number: Int?, among browsers: [BrowserPaneReport], tool: String
    ) -> Result<BrowserPaneReport, PaneRefusal> {
        guard !browsers.isEmpty else {
            return .failure(
                PaneRefusal(
                    "There is no browser open in this workspace, so \(tool) has nothing to look "
                        + "at. Open one with pane_open, or call pane_list to see what is open."
                )
            )
        }

        guard let number else {
            guard browsers.count == 1 else {
                return .failure(
                    PaneRefusal(
                        "There are \(browsers.count) browsers open, so \(tool) needs a 'browser' "
                            + "number to say which: \(list(browsers))."
                    )
                )
            }
            return .success(browsers[0])
        }

        guard let found = browsers.first(where: { $0.number == number }) else {
            return .failure(
                PaneRefusal(
                    "There is no browser \(number) in this workspace. The ones that are open are "
                        + "\(list(browsers)). The numbers change when a tab is closed, so call "
                        + "pane_list again."
                )
            )
        }
        return .success(found)
    }

    /// The browsers, named the way the refusals name them: the number and where it is pointed.
    ///
    /// The address rather than the tab's name, because a name is the page's `<title>` and three
    /// tabs on one site carry the same one, which would leave the model choosing between three
    /// identical options.
    private static func list(_ browsers: [BrowserPaneReport]) -> String {
        browsers.map { "\($0.number) on \($0.address.isEmpty ? "no page yet" : $0.address)" }
            .joined(separator: ", ")
    }
}

/// What each of them is called on the wire.
///
/// Named rather than written out at each site because the name appears three times for every tool:
/// in its own declaration, in `BridgeToolApproval.selfApproved`, and in the refusals the window
/// gives when a call has to be made again with a number in it. A tool renamed in two of the three
/// is a tool that tells the model to call something that does not exist.
public enum BrowserPaneToolName {
    public static let read = "browser_read"
    public static let reload = "browser_reload"
    public static let go = "browser_go"
    public static let screenshot = "browser_screenshot"
    public static let scroll = "browser_scroll"
    public static let text = "browser_text"
    public static let snapshot = "browser_snapshot"
    public static let click = "browser_click"
    public static let fill = "browser_fill"
    public static let press = "browser_press"
    public static let wait = "browser_wait"
    public static let console = "browser_console"
    public static let network = "browser_network"
}
