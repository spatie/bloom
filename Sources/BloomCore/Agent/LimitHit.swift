import Foundation

/// Which wall a failed turn ran into, read from the `rate_limit_event` Claude Code sends with it.
///
/// The CLI's own sentence leads with whatever refused the extra spend ("You've hit your org's
/// monthly spend limit · ... · your 5-hour limit resets 11:30am"), which reads as though the month
/// were the wall. The event carries both facts as tokens, so Bloom says them in order.
public struct LimitHit: Sendable, Hashable {
    /// Claude's `rateLimitType`: `five_hour`, `seven_day`, or a model scoped week.
    public let window: String
    public let resetsAt: Date?
    /// Claude's `overageDisabledReason`, when extra usage refused to cover the turn.
    public let creditRefusal: String?

    public init(window: String, resetsAt: Date?, creditRefusal: String?) {
        self.window = window
        self.resetsAt = resetsAt
        self.creditRefusal = creditRefusal
    }

    /// A `rejected` event, which is the wall itself. Anything else is a reading, not a hit.
    public static func read(rateLimitEvent data: Data) -> LimitHit? {
        guard let line = JSONValue.parse(data),
              line["type"]?.stringValue == "rate_limit_event",
              let info = line["rate_limit_info"],
              info["status"]?.stringValue == "rejected",
              let window = info["rateLimitType"]?.stringValue
        else { return nil }
        let refused = info["overageStatus"]?.stringValue == "rejected"
        return LimitHit(
            window: window,
            resetsAt: info["resetsAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0) },
            creditRefusal: refused ? info["overageDisabledReason"]?.stringValue ?? "" : nil
        )
    }

    /// The hit of the turn closing at the end of `rows`, walked back from its result. A user row
    /// opens the turn, so nothing before it belongs to this failure.
    public static func latest(walkingBack rows: some Sequence<(kind: MessageKind, payload: Data)>) -> LimitHit? {
        for row in rows {
            if row.kind == .user { return nil }
            if row.kind == .notice, let hit = read(rateLimitEvent: row.payload) { return hit }
        }
        return nil
    }

    /// Bloom's lead under the failed turn: the window first, then why credits did not take over.
    public func lead(clock: ResetClock = ResetClock()) -> String {
        var sentence = "The \(windowName) is reached"
        if let creditClause { sentence += ", and \(creditClause)" }
        let until = resetsAt.map { "until it resets \(clock.phrase($0))" } ?? "until it resets"
        return sentence + ", so nothing more can run \(until). Nothing is lost, and the chat can "
            + "pick up where it stopped."
    }

    private var windowName: String {
        if window == "five_hour" { return "5-hour session limit" }
        if window.hasPrefix("seven_day") { return "weekly limit" }
        return "usage limit"
    }

    private var creditClause: String? {
        switch creditRefusal {
        case nil: nil
        case "org_level_disabled_until": "the organisation's monthly extra usage budget is spent"
        case "org_level_disabled": "extra usage is turned off for the organisation"
        case "member_zero_credit_limit": "this account has no extra usage credit"
        default: "extra usage cannot cover it"
        }
    }
}
