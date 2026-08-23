import Foundation

/// Folds a fresh report about an allowance into what Bloom already knew about it.
///
/// **This exists because one of the two providers says so in its own schema.** Codex's
/// `account/rateLimits/updated` is documented, verbatim, as:
///
/// > Sparse rolling rate-limit update.
/// >
/// > Clients should merge available values into the most recent `account/rateLimits/read`
/// > response or refetch that snapshot. Nullable account metadata may be unavailable in a rolling
/// > update and does not clear a previously observed value.
///
/// Bloom read that notification as the whole truth. Everything on Codex's `RateLimitWindow` is
/// nullable except `usedPercent`, so a rolling update carrying a percentage and nothing else was
/// either thrown away (no `windowDurationMins`, so the adapter declined the row) or written over
/// a good reset time with nothing. Either way the panel got worse for having been told something.
///
/// The rule is one sentence: **a report states what it states, and says nothing about what it
/// leaves out.** A missing field keeps the value already on file. That is not provider specific
/// and it is not a Codex workaround, so it is applied to every provider: Claude Code's
/// `rate_limit_event` omits `utilization` below its warning threshold for exactly the same reason
/// and deserves exactly the same treatment.
///
/// **With one exception, and it is the important one.** A field is only carried forward while the
/// row is still describing the same window. When a report brings a reset time that is not the one
/// on file, the allowance has turned over: the old percentage is a measurement of a window that no
/// longer exists, and carrying it forward would be the stalest possible lie in the one place a
/// person looks to decide whether to keep working. So a changed reset time drops everything the
/// report did not restate, and the row goes back to `.unknown` until somebody measures it again.
public enum QuotaMerge {
    /// Everything known after `reported` arrives, keeping any row nobody mentioned.
    ///
    /// Rows are matched on `AgentQuota.id`, which is the provider and the window key, because that
    /// is the same key `Store.recordQuotas` upserts on. A reported row with no counterpart is new
    /// and is taken as it stands.
    public static func merged(_ known: [AgentQuota], with reported: [AgentQuota]) -> [AgentQuota] {
        var byID = Dictionary(known.map { ($0.id, $0) }, uniquingKeysWith: { _, later in later })
        for row in reported {
            byID[row.id] = resolve(row, against: byID[row.id])
        }
        return byID.values.sorted { $0.id < $1.id }
    }

    /// Only the rows worth writing: the reported ones, filled in from what was on file.
    ///
    /// This is what the app hands to the store. The union above is the honest answer to "what does
    /// Bloom know now", but writing every untouched row back would restamp its `observedAt` and
    /// make a figure nobody has confirmed for an hour look like it arrived this second.
    public static func resolved(_ reported: [AgentQuota], against known: [AgentQuota]) -> [AgentQuota] {
        let byID = Dictionary(known.map { ($0.id, $0) }, uniquingKeysWith: { _, later in later })
        return reported.map { resolve($0, against: byID[$0.id]) }
    }

    /// One report, against the one row it is about.
    ///
    /// A report older than what is on file is dropped whole rather than merged. Two askers can be
    /// in flight at once (a poll and a turn's own notification), and the second answer to come
    /// back is not necessarily the later reading.
    public static func resolve(_ reported: AgentQuota, against known: AgentQuota?) -> AgentQuota {
        guard let known else { return reported }
        guard reported.observedAt >= known.observedAt else { return known }

        var merged = reported
        merged.resetsAt = reported.resetsAt ?? known.resetsAt

        // The window has turned over, so nothing that was measured against the old one survives.
        // `nil` on either side is not a change: a report that did not mention a reset time has not
        // claimed the window moved, and a row that never had one has nothing to compare against.
        let turnedOver: Bool
        if let old = known.resetsAt, let new = merged.resetsAt {
            turnedOver = old != new
        } else {
            turnedOver = false
        }
        guard !turnedOver else { return merged }

        if !reported.measure.isKnown { merged.measure = known.measure }
        // A window is a key, a label and a length. The key is the match, so only the other two can
        // be missing, and they go together: a label without the length it was derived from would
        // outlive the number it describes.
        if reported.window.duration == nil, known.window.duration != nil {
            merged.window = known.window
        }
        return merged
    }
}

/// How old a figure is, and whether it is old enough to say so.
///
/// **A number with no age on it is a claim about now.** Bloom's figures arrive when a provider is
/// asked, and between asks the panel is showing history. That is fine and it is what everybody
/// expects of a limits panel; what is not fine is a five hour window drawn at 40 percent from a
/// reading taken this morning, which is the one thing worse than the "not reported" this feature
/// replaces.
///
/// The threshold is the poll interval plus a margin, so an app that is polling normally never
/// says anything: an age within one poll of now is what "current" means here. Past that, something
/// has stopped, and the panel says how long ago rather than pretending.
public enum QuotaFreshness: Sendable, Hashable {
    /// Measured within the last poll or so. Nothing to say.
    case current
    /// Older than that, by this much.
    case stale(TimeInterval)

    /// An age past which the panel starts saying how old a figure is.
    ///
    /// Two poll intervals. One would flag every reading in the moments before its own refresh,
    /// which is the panel calling normal operation stale; two means a figure is only ever marked
    /// once a poll has actually been missed.
    public static let threshold = QuotaPollSchedule.interval * 2

    public static func of(_ observedAt: Date, at now: Date = Date()) -> QuotaFreshness {
        let age = now.timeIntervalSince(observedAt)
        return age > threshold ? .stale(age) : .current
    }

    /// The oldest reading on a board, which is the one the panel has to answer for.
    public static func of(_ board: QuotaBoard, at now: Date = Date()) -> QuotaFreshness {
        guard let oldest = board.all.map(\.observedAt).min() else { return .current }
        return of(oldest, at: now)
    }

    /// How long ago, said the way a person would, or nothing when there is nothing to say.
    ///
    /// Coarse, and for the same reason `QuotaCountdown` is: the menu is built when it opens and
    /// held still while it is up, so a figure counting seconds would be wrong as it was drawn.
    public var phrase: String? {
        guard case .stale(let age) = self else { return nil }
        if age < 3600 { return "\(Int((age / 60).rounded(.down))) min ago" }
        if age < 86_400 {
            let hours = Int((age / 3600).rounded(.down))
            return hours == 1 ? "an hour ago" : "\(hours) hours ago"
        }
        let days = Int((age / 86_400).rounded(.down))
        return days == 1 ? "yesterday" : "\(days) days ago"
    }
}
