import Foundation

/// Whether a `rate_limit_event` is worth a line in the transcript, and what that line says.
///
/// **The same fact arrives twice.** Every `rate_limit_event` is already read by
/// `AgentQuotaAdapters` and recorded against the account, which is where the menu bar's limits
/// panel gets its figures. It is *also* stored as a `.notice` row and drawn in the transcript. Two
/// readings of one line is fine on its own; what was not fine is that the two disagreed.
///
/// The panel's reading is careful: `utilization` is absent from the payload until the account is
/// near the wall, which is exactly what the real capture shows, and the adapter stores that as
/// `.unknown` rather than as zero. The transcript's reading defaulted the same missing field to
/// nought and printed "0% of the five hour window used" under a turn on an account whose usage
/// nobody had reported. That is a figure Bloom invented, sitting in the one place a person reads
/// as the record of what happened.
///
/// So the row is only drawn when the event carries a figure. That is not merely the safe rule, it
/// is the meaningful one: the CLI omits `utilization` until it crosses its own warning threshold,
/// so an event with a number in it is the CLI saying this is now worth mentioning, and an event
/// without one is a heartbeat that the panel already absorbs. The running figure lives in the
/// panel, where it can be looked at on purpose; the transcript gets the news.
public enum RateLimitNotice {
    /// What the row says, or nothing when there is no row to draw.
    public static func sentence(forRateLimitEvent data: Data, at now: Date = Date()) -> String? {
        let quotas = AgentQuotaAdapters.quotas(fromRateLimitEvent: data, at: now)
        // One window per event on both protocols. The largest share is taken rather than the first
        // so that a provider which does start sending two cannot bury the one that matters.
        guard let worst = quotas.compactMap({ quota -> (String, Double)? in
            guard let fraction = quota.measure.fraction else { return nil }
            return (quota.window.label, fraction)
        }).max(by: { $0.1 < $1.1 }) else { return nil }

        let percent = Int((worst.1 * 100).rounded())
        return "\(percent)% of the \(worst.0.lowercased()) allowance used"
    }
}
