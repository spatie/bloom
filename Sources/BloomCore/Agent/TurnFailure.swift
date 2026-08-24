import Foundation

/// What a `result` line that failed is worth saying, and whose words say it.
///
/// **The case this was written for really happens**, and it is in
/// `Tests/fixtures/claude-turn-died-mid-response.ndjson`: a result whose `subtype` is `success`,
/// whose `is_error` is true, whose `terminal_reason` is `api_error`, and whose `result` reads
/// "API Error: Connection lost mid-response. The response above may be incomplete." Bloom read
/// that correctly as a failure and then drew a small red circle, the duration, and nothing else.
/// The CLI's own explanation was on the row the whole time, reachable only through the footer's
/// copy menu. A turn that died mid sentence therefore looked like a turn that had simply gone
/// wrong for no stated reason, next to eighty seconds nobody could account for.
///
/// # Bloom's sentence over the CLI's, with the CLI's kept
///
/// The CLI's prose is written for a terminal: it names status pages, it is addressed to somebody
/// who typed a command, and it is punctuated in a register this app does not use anywhere else.
/// Passing it through untouched is defensible on the grounds that it is genuinely somebody else's
/// message, and that is the argument for the second half of what happens here: it is kept, whole,
/// and it is the last thing in the block.
///
/// What is not defensible is passing it through as though Bloom had written it, because then the
/// one time a person most needs the app to be plain, the app is quoting. So a terminal reason
/// Bloom recognises gets Bloom's own lead sentence in Bloom's own register, saying what happened
/// and whether anything is asked of the reader; the CLI's words follow, marked as the CLI's. A
/// reason Bloom does not recognise gets no lead at all, and the CLI's words stand alone rather
/// than being wrapped in a sentence that pretends to a diagnosis nobody made.
public struct TurnFailure: Sendable, Hashable {
    /// Bloom's own account, or nothing when Bloom has no reading of this ending.
    public let lead: String?
    /// What the CLI said, unedited, or nothing when it said nothing.
    public let clisOwnWords: String?

    /// Reads a failed result. Returns nil for a result that did not fail, and for one that failed
    /// with nothing at all to show, where a footer's red mark is already the whole of what is
    /// known.
    public static func of(_ result: AgentResult) -> TurnFailure? {
        guard !result.succeeded else { return nil }
        let words = result.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let lead = self.lead(terminalReason: result.terminalReason, stopReason: result.stopReason)
        guard lead != nil || !words.isEmpty else { return nil }
        return TurnFailure(lead: lead, clisOwnWords: words.isEmpty ? nil : words)
    }

    /// Diagnosed from `terminal_reason`, which is a token rather than a sentence, so there is
    /// nothing here parsing anybody's prose.
    ///
    /// Deliberately short of a list of every token the CLI might ever emit. Each one here is a
    /// distinct thing to say; a token not on the list falls through to the CLI's own words, which
    /// is the honest answer to an ending Bloom has never seen.
    static func lead(terminalReason: String?, stopReason: String?) -> String? {
        switch terminalReason {
        case "api_error":
            return "The turn stopped part way through, at the API's end rather than yours. "
                + "Whatever the agent had already changed is still in the worktree, and you can "
                + "ask again whenever you like."
        case "max_tokens":
            return "The turn ran out of room to answer in. Nothing is lost, and a narrower "
                + "question will fit."
        default:
            return nil
        }
    }
}
