import Foundation

/// Something Bloom decided on the reader's behalf, in words they can read.
///
/// Its own type rather than a pair of strings because two things in a browser pane raise one now,
/// a page refused more windows and a page refused more downloads, and the app presents both the
/// same way. See `BrowserPaneHost.report`.
public struct BrowserNotice: Sendable, Equatable {
    public var title: String
    public var message: String

    public init(title: String, message: String) {
        self.title = title
        self.message = message
    }
}

/// How often a page may make something happen outside itself, counted over a rolling window.
///
/// **A rate limit rather than a permission, and the difference is the point.** A reader clicking
/// links that open in a new tab, or pressing a download button twice, is doing the ordinary thing
/// and must not be asked about it. A page in a loop calling `window.open` or pointing an iframe at
/// an attachment a thousand times must not be able to fill the strip or the disk. There is no
/// signal in WebKit's delegate callbacks that says a human pressed the mouse, so those two are
/// told apart by how fast they arrive and by nothing else, and a handful in a few seconds is above
/// anything a hand does and far below what a loop does in one frame.
///
/// **The first refusal in a run says so and the rest are silent.** A loop refused a thousand times
/// would otherwise put up a thousand dialogs, which is the same denial of service by another door.
/// Something being allowed again arms the notice, which is what a reader clicking a link a minute
/// later does.
///
/// The clock is passed in rather than read here, so the suite can drive it. Every caller in the
/// app passes `Date()`.
public struct BrowserBurst: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        case allowed
        /// Over the limit, and the reader has already been told about this run.
        case refused
        /// Over the limit, and this is the first refusal since anything was last allowed, so this
        /// is the one that carries a sentence.
        case refusedAndUnsaid
    }

    public let limit: Int
    public let window: TimeInterval

    /// When each of the recent allowances was given, oldest first. Pruned on every call, so it
    /// never holds more than `limit` entries.
    private var moments: [Date] = []
    private var hasSaidSo = false

    public init(limit: Int, window: TimeInterval) {
        self.limit = limit
        self.window = window
    }

    public mutating func take(at now: Date) -> Verdict {
        moments.removeAll { now.timeIntervalSince($0) >= window }
        guard moments.count < limit else {
            guard !hasSaidSo else { return .refused }
            hasSaidSo = true
            return .refusedAndUnsaid
        }
        moments.append(now)
        hasSaidSo = false
        return .allowed
    }
}
