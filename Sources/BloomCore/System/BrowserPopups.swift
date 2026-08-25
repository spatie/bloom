import Foundation

/// What happens when a page in a browser pane asks for a window of its own.
///
/// A `target="_blank"` link and a `window.open` call arrive at the same place, and until now that
/// place did nothing at all: `WKUIDelegate.createWebViewWith` was never implemented, so WebKit
/// took the default answer of nil and the click looked broken. Bloom's answer is a second browser
/// tab in the same workspace, and this is the rule that decides whether the page gets one.
///
/// **How many is `BrowserBurst`**, which is where the argument for a rate limit rather than a
/// permission is written down, and which counts a page's downloads the same way. Five in five
/// seconds is above anything a hand does and far below what a loop does in one frame.
///
/// **A scheme a browser pane cannot show is refused quietly.** `window.open("mailto:...")` and
/// anything with a custom scheme are not addresses this pane can hold, and handing one to
/// `NSWorkspace` instead would let a page launch applications on this Mac by writing one line of
/// script. That is a capability the pane has never had and this is not the change that grants it.
/// The test is `BrowserAddress.shows`, which is the same one the transcript's link menu asks.
public struct BrowserPopups: Sendable, Equatable {
    /// What to tell the reader, when there is anything to tell them.
    public typealias Notice = BrowserNotice

    public enum Decision: Sendable, Equatable {
        /// Open a browser tab on this address, in front.
        case open(URL)
        /// Nothing happens and nothing is said.
        case refuse
        /// Nothing happens, and the reader is told once why.
        case refuseAndSay(Notice)
    }

    private var burst: BrowserBurst

    public init(limit: Int = 5, window: TimeInterval = 5) {
        burst = BrowserBurst(limit: limit, window: window)
    }

    /// Asks whether a page may open `url` in a tab of its own, and records the answer.
    public mutating func request(_ url: URL?, at now: Date = Date()) -> Decision {
        // A page that calls `window.open()` with no address gets an empty window in a browser, and
        // an empty window is not a thing this pane can be: a browser tab pointed nowhere shows an
        // address field the page cannot then reach. Nothing to show, so nothing happens.
        //
        // Asked before the burst is counted, so a page firing `mailto:` at the delegate cannot
        // spend the allowance the reader's next real link needs.
        guard let url, BrowserAddress.shows(url) else { return .refuse }

        switch burst.take(at: now) {
        case .allowed: return .open(url)
        case .refused: return .refuse
        case .refusedAndUnsaid: return .refuseAndSay(Self.notice(for: url))
        }
    }

    /// The sentence the first refusal carries.
    ///
    /// It names the host rather than the whole address, because the address of the thousandth
    /// window a loop asked for says nothing and a dialog is not the place for a query string. It
    /// says what Bloom did rather than what the page did, because "a page tried to" reads as an
    /// accusation the reader has to act on and there is nothing for them to do.
    private static func notice(for url: URL) -> Notice {
        let host = url.host() ?? "That page"
        return Notice(
            title: "Bloom stopped \(host) opening more tabs",
            message: """
                This page asked for several browser tabs at once, which is what a page in a loop \
                does. Bloom opened the first few and refused the rest. Reload the page if you were \
                expecting them.
                """
        )
    }
}
