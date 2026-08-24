import Foundation
import BloomCore

/// How full the model's context window is, and everything the protocol will say about it.
///
/// Two numbers, from two different lines of the stream, because Claude Code reports them nowhere
/// together.
///
/// **The limit** comes from `result.modelUsage.<model>.contextWindow`, which only appears on the
/// line that closes a turn.
///
/// **What is in the window** comes from the last `assistant` event, whose `usage` describes the one
/// API call that produced it: `input_tokens + cache_read_input_tokens + cache_creation_input_tokens`
/// is exactly what the model was handed. The `usage` on the `result` line cannot be used for this.
/// It is the SUM over every API call the turn made, so a turn with ten tool calls reports roughly
/// ten times the context it actually had, and the fuller the window the worse it reads.
///
/// There is no breakdown. The protocol never says how much of the window is the system prompt, or
/// skills, or memory files, or MCP tool definitions, so this deliberately carries a total and
/// nothing that would have to be guessed at.
struct ContextWindowUsage: Equatable {
    /// Tokens the model had in front of it on the last call.
    var used: Int
    /// The size of the window, as the model reported it.
    var limit: Int

    var fraction: Double {
        limit > 0 ? min(1, Double(used) / Double(limit)) : 0
    }

    var remaining: Int { max(0, limit - used) }

    /// Where the gauge stops being an ordinary readout and starts being a warning.
    ///
    /// One number in one place. It was the literal `0.8` in `ComposerContextGauge` and the literal
    /// `0.8` in `ContextWindowDetail`, which is two copies of a threshold that has to agree or the
    /// bar in the popover contradicts the bar that opened it.
    static let crowdedAt = 0.8

    /// Whether the window is filling up. The gauge draws this as amber and nothing else, so it is
    /// also what the spoken value has to say: a reader who cannot see the tint used to get the
    /// number and no indication that the number was a problem.
    var isCrowded: Bool { fraction >= Self.crowdedAt }

    /// The most recent reading a whole transcript holds, or nil when the session has not run a
    /// turn yet and so has never been told either number.
    ///
    /// For the one caller that has the whole list and nothing held: a session being read back off
    /// disk. Everything after that goes through `updated(_:with:)` below, because this walk cannot
    /// stop early when there is no answer to find.
    @MainActor
    static func latest(in rows: [TranscriptRow]) -> Self? {
        updated(nil, with: rows)
    }

    /// What newly arrived rows say about the window, folded onto what was already known.
    ///
    /// **The two numbers arrive on different lines, and neither is on every line.** The limit only
    /// appears on the line that closes a turn and what is in the window only on an assistant or
    /// thinking block, so each is kept until something newer replaces it rather than being
    /// recomputed from the whole transcript. Nought means "this line did not say", never "the
    /// window is empty", which is why neither is ever overwritten with one.
    ///
    /// Walked backwards and stopped as soon as both numbers are in hand, because the answer is in
    /// the last few rows of whatever it is handed.
    ///
    /// Rows from inside a subagent are skipped: the Agent tool runs its own conversation with its
    /// own window, and its usage says nothing about the one the composer is about to add to.
    @MainActor
    static func updated(
        _ held: Self?, with rows: some BidirectionalCollection<TranscriptRow>
    ) -> Self? {
        var used = 0
        var limit = 0

        for row in rows.reversed() {
            guard row.parentToolUseID == nil else { continue }
            switch row.kind {
            case .result where limit == 0:
                if case .result(let result)? = event(of: row) {
                    limit = result.usage.contextTokens
                }
            case .assistantText, .thinking:
                guard used == 0 else { continue }
                switch event(of: row) {
                case .assistantText(let block)?, .thinking(let block)?:
                    used = block.usage.contextUsedTokens
                default:
                    break
                }
            default:
                continue
            }
            if used > 0, limit > 0 { break }
        }

        if used == 0 { used = held?.used ?? 0 }
        if limit == 0 { limit = held?.limit ?? 0 }
        guard used > 0, limit > 0 else { return nil }
        return Self(used: used, limit: limit)
    }

    @MainActor
    private static func event(of row: TranscriptRow) -> AgentEvent? {
        TranscriptEventCache.event(rowID: row.id, payload: row.payload)
    }

    /// `174.0k`, `1.0M`, `820`. The shape Claude Code's own status line uses, so a number read here
    /// and a number read there are the same number.
    static func format(_ tokens: Int) -> String {
        switch tokens {
        case 1_000_000...:
            "\((Double(tokens) / 1_000_000).formatted(.number.precision(.fractionLength(1))))M"
        case 1_000...:
            "\((Double(tokens) / 1_000).formatted(.number.precision(.fractionLength(1))))k"
        default:
            "\(tokens)"
        }
    }

    /// Rounded to whole points. A gauge that reads 6.3% claims a precision the numbers behind it
    /// do not have, since the next turn's prompt is not in them yet.
    static func percent(_ fraction: Double) -> String {
        (fraction).formatted(.percent.precision(.fractionLength(0)))
    }

    /// Everything the gauge puts into words: what it shows, and what it says to a reader who
    /// cannot see it.
    ///
    /// Built once by the footer and handed down, rather than by the gauge's own body. The footer
    /// draws its row inside a `ViewThatFits` with three candidates and two of them hold the gauge,
    /// so a sentence assembled in that body cost four `FormatStyle` invocations twice over on
    /// every pass, for one control that reports and does nothing.
    struct Reading: Equatable {
        /// What is drawn beside the bar.
        var percent: String
        /// The whole reading, spoken. The crowded state is drawn as amber and as nothing else, so
        /// it has to be said here or a reader gets the number with no indication that the number
        /// is a problem.
        var spoken: String
    }

    var reading: Reading {
        Reading(
            percent: Self.percent(fraction),
            spoken: "\(Self.percent(fraction)) used, "
                + "\(Self.format(used)) of \(Self.format(limit)) tokens"
                + (isCrowded ? ", filling up" : "")
        )
    }
}
