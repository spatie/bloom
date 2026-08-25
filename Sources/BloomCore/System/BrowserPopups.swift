import Foundation

/// What happens when a page in a browser pane asks for a window of its own.
///
/// A `target="_blank"` link and a `window.open` call arrive at the same place, and until now that
/// place did nothing at all: `WKUIDelegate.createWebViewWith` was never implemented, so WebKit
/// took the default answer of nil and the click looked broken. Bloom's answer is a second browser
/// tab in the same workspace, and this is the rule that decides whether the page gets one.
///
/// **It is a rate limit rather than a permission**, and the difference is the point. A reader
/// clicking links that open in a new tab is doing the ordinary thing and must not be asked about
/// it; a page in a loop calling `window.open` a thousand times must not be able to fill the strip
/// with a thousand tabs. Those two are told apart by how fast they arrive and by nothing else,
/// because there is no signal in `WKNavigationAction` that says a human pressed the mouse. Five in
/// five seconds is above anything a hand does and far below what a loop does in one frame.
///
/// **The first refusal says so and the rest are silent.** A loop that is refused a thousand times
/// would otherwise put up a thousand alerts, which is the same denial of service by another door.
/// So the notice is carried on the first refusal after a run of allowed openings and on no other,
/// and the count is reset by an opening being allowed again, which is what a reader clicking a
/// link a minute later does.
///
/// **A scheme a browser pane cannot show is refused quietly.** `window.open("mailto:...")` and
/// anything with a custom scheme are not addresses this pane can hold, and handing one to
/// `NSWorkspace` instead would let a page launch applications on this Mac by writing one line of
/// script. That is a capability the pane has never had and this is not the change that grants it.
/// The test is `BrowserAddress.shows`, which is the same one the transcript's link menu asks.
public struct BrowserPopups: Sendable, Equatable {
    /// What to tell the reader, when there is anything to tell them.
    public struct Notice: Sendable, Equatable {
        public var title: String
        public var message: String

        public init(title: String, message: String) {
            self.title = title
            self.message = message
        }
    }

    public enum Decision: Sendable, Equatable {
        /// Open a browser tab on this address, in front.
        case open(URL)
        /// Nothing happens and nothing is said.
        case refuse
        /// Nothing happens, and the reader is told once why.
        case refuseAndSay(Notice)
    }

    /// How many windows a page may open in `window` seconds.
    public var limit: Int
    /// The length of the rolling window the limit is counted over, in seconds.
    public var window: TimeInterval

    /// When each of the recent openings was allowed, oldest first. Pruned on every request, so it
    /// never holds more than `limit` entries.
    private var openings: [Date] = []
    /// Whether the reader has already been told about this run of refusals.
    private var hasSaidSo = false

    public init(limit: Int = 5, window: TimeInterval = 5) {
        self.limit = limit
        self.window = window
    }

    /// Asks whether a page may open `url` in a tab of its own, and records the answer.
    ///
    /// `now` is passed in rather than read here so the suite can drive the clock. Every caller in
    /// the app passes `Date()`.
    public mutating func request(_ url: URL?, at now: Date = Date()) -> Decision {
        // A page that calls `window.open()` with no address gets an empty window in a browser, and
        // an empty window is not a thing this pane can be: a browser tab pointed nowhere shows an
        // address field the page cannot then reach. Nothing to show, so nothing happens.
        guard let url, BrowserAddress.shows(url) else { return .refuse }

        openings.removeAll { now.timeIntervalSince($0) >= window }
        guard openings.count < limit else {
            guard !hasSaidSo else { return .refuse }
            hasSaidSo = true
            return .refuseAndSay(Self.notice(for: url))
        }

        openings.append(now)
        hasSaidSo = false
        return .open(url)
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
