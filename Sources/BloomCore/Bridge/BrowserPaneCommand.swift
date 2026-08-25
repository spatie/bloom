import Foundation

/// Looking at, and moving, a browser pane the reader has open.
///
/// One value for six tools, for the reason `PaneOrder` is one value for two: `browser_read`,
/// `browser_reload`, `browser_go`, `browser_screenshot`, `browser_scroll` and `browser_text` all
/// ask the same question first, which is "which of the reader's browsers do you mean", and a
/// second copy of that answer is how two of them would come to disagree about it.
///
/// ## Why there is no `browser_eval`, and what stands in for it
///
/// The obvious tool is not here. `WKWebView.evaluateJavaScript` would turn these six into a real
/// automation surface in an afternoon: click that, fill that in, read that out, wait for that.
/// Every browser automation library is that one call. It was asked for, in the words "all possible
/// browser automation", and the answer is no. The reason is what the pane actually is.
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
/// **So the substitute is the narrow tool rather than the general one.** What the owner asked for
/// underneath the words was for the agent to be able to SEE the pane: which tabs there are, where
/// they are pointed, what is on the page, and to be able to move it about. Every one of those is
/// its own verb here, and each is a thing Bloom does rather than a thing the caller describes:
/// read the toolbar, take a picture, read the visible text, scroll, reload, go to an address. The
/// scripts behind the last three are written out in full in `BrowserPageScript` and the only thing
/// a caller contributes to any of them is an integer.
///
/// What that costs is real and should be stated rather than glossed: an agent cannot click a
/// button on the page, cannot fill in a form, cannot read a value out of an input, and cannot wait
/// for a selector. An agent that needs those has `agent-browser` and a Chrome of its own, which is
/// what the answer to the original question already pointed at, and the difference is that nobody
/// is logged in there as him.
///
/// If it is ever wanted, the shape it has to take is a setting the owner turns on per project,
/// off by default, with the tool refused to every role but `.parent`, never self-approved, and the
/// script shown in full in the prompt. That is a change to make deliberately and with him asked
/// first, and it is not this one.
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
        }
    }

    /// Which browser the call named, or nothing for "the one that is open".
    public var number: Int? {
        switch self {
        case .read(let number), .reload(let number), .go(let number, _),
             .screenshot(let number), .scroll(let number, _), .text(let number):
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

/// How a caller names one of the reader's browsers.
///
/// **A number from `pane_list` and nothing else.** The alternatives were considered and are all
/// worse. A tab id is a uuid, which a model cannot read, cannot repeat to a person and can carry
/// in from somewhere stale. A name is the page's own title most of the time, so it changes under
/// the caller as the page navigates and two tabs on one site share it. A kind, which is what
/// `pane_close` and `pane_rename` take, works only while there is one of the thing, and browsers
/// are the pane a reader has several of.
///
/// So: 1, 2, 3, left to right in the strip, exactly as `pane_list` prints them. It is a handle
/// that lives as long as the listing that produced it, which is stated in every tool description
/// rather than pretended away.
public enum BrowserPaneChoice {
    /// Reads the `browser` argument: an integer, or nothing.
    ///
    /// A float is refused rather than rounded. A model that passes 1.5 has not counted along the
    /// strip, it has computed something, and rounding would act on a pane it did not choose.
    public static func parse(_ raw: JSONValue?, tool: String) -> Result<Int?, PaneRefusal> {
        switch raw {
        case .none, .null:
            return .success(nil)
        case .integer(let number):
            guard number >= 1 else {
                return .failure(
                    PaneRefusal(
                        "'browser' is the number pane_list gives a browser, counting from 1. "
                            + "\(number) is not one of them."
                    )
                )
            }
            return .success(number)
        default:
            return .failure(
                PaneRefusal(
                    "'browser' is a whole number, as pane_list prints it. Leave it out when there "
                        + "is only one browser open, and call pane_list first when there is more "
                        + "than one."
                )
            )
        }
    }

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

/// What each of the six is called on the wire.
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
}
