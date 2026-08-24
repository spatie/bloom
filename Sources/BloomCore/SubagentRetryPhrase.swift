import Foundation

/// What a subagent's row says while the API is refusing it.
///
/// **This is a seam, and the word in it is a placeholder.** The retry and error surfaces are one
/// piece of work: `api_retry`, `subagent_retry` and what a failed result reads like all have to
/// agree on a vocabulary, and picking a sentence here in isolation would guarantee the sidebar
/// said one thing while the transcript said another about the same 529.
///
/// So the FACTS are parsed, tested and already on the row: `SubagentRetry` carries the attempt,
/// the ceiling, the delay, the HTTP status and the CLI's own category, and `SubagentRow.detail`
/// hands the whole struct over rather than a string. Only the phrasing is deferred, to here, in
/// one function with one caller.
public enum SubagentRetryPhrase {
    /// - Returns: the short phrase a 260 point row has space for, beside the subagent's name.
    public static func text(_ retry: SubagentRetry) -> String {
        "retrying"
    }
}
