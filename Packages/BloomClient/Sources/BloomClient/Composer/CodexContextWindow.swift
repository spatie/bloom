import Foundation

/// How large a Codex chat's context window is told to be, and where it starts compacting.
///
/// Codex sizes its window from its own model catalogue, and the catalogue's number is well under
/// what the model will actually take: `gpt-5.6-sol` is served a fraction of the window it has.
/// The CLI's way out is two config overrides, which is what a Codex user types by hand today:
///
///     codex -c model_context_window=1000000 -c model_auto_compact_token_limit=900000
///
/// **Both, never one.** `model_context_window` alone widens what the server will pack into a
/// request and leaves auto-compaction firing at the catalogue's old limit, so the chat compacts
/// at a fraction of a window it has just been told is much larger, which is the worst of the two
/// settings rather than a halfway house. `model_auto_compact_token_limit` alone pushes compaction
/// past the window and the turn fails on the model's own limit instead. So one choice is made
/// here and it writes both keys.
///
/// The compaction limit is a fraction of the window rather than a second thing to pick. Nothing
/// in the protocol reports how much room a compaction needs, 90% is what the shared recipe uses,
/// and a second number in the picker would be a second thing to get wrong.
///
/// **A launch argument, not a turn argument.** Model, effort, approval policy and sandbox all
/// travel with `turn/start` and take effect on the next message; these two are read when
/// `codex app-server` starts. `CodexRunner` is what closes that gap, by reconnecting when the
/// value it launched with is no longer the value the chat is set to.
public enum CodexContextWindow {
    /// Leave Codex's own catalogue alone, which is what every chat is until somebody says
    /// otherwise. Zero rather than nil so the value fits a settings row, a picker tag and a
    /// comparison without an optional at every step.
    public static let modelDefault = 0

    /// What the picker offers, narrowest first.
    ///
    /// Two overrides and no more. Anything below the catalogue's own figure would be a control
    /// for making a chat worse, and the two here are the sizes the request asked for.
    public static let choices = [modelDefault, 500_000, 1_000_000]

    /// How full the window is allowed to get before Codex compacts, as a fraction of it.
    static let compactAt = 0.9

    /// Where auto-compaction starts, for a given window. Zero for the model's own window, which
    /// means the override is not written at all rather than written as zero.
    public static func autoCompactLimit(for tokens: Int) -> Int {
        guard tokens > 0 else { return 0 }
        return Int((Double(tokens) * compactAt).rounded())
    }

    /// The `-c` pair this choice adds to `codex app-server`, or nothing for the model's own
    /// window. Written as separate `-c` arguments rather than one comma-joined value, which is
    /// the form `BridgeRegistration.codexArguments` already uses and the only form the CLI
    /// documents.
    public static func overrides(for tokens: Int) -> [String] {
        guard tokens > 0 else { return [] }
        return [
            "-c", "model_context_window=\(tokens)",
            "-c", "model_auto_compact_token_limit=\(autoCompactLimit(for: tokens))",
        ]
    }

    /// What the picker draws. "Default" for the model's own, and the round numbers as the people
    /// asking for them write them: 500K, 1M.
    public static func label(for tokens: Int) -> String {
        guard tokens > 0 else { return "Default" }
        if tokens >= 1_000_000, tokens.isMultiple(of: 1_000_000) {
            return "\(tokens / 1_000_000)M"
        }
        if tokens >= 1_000, tokens.isMultiple(of: 1_000) {
            return "\(tokens / 1_000)K"
        }
        return "\(tokens)"
    }

    /// The rows the picker draws, including whatever this chat is already set to.
    ///
    /// A settings file or an older build can leave a chat on a size that is not on the list, and a
    /// picker that quietly drops it is a picker that cannot put it back. Same rule, and the same
    /// bug behind it, as `ComposerOption.adding`.
    public static func options(including current: Int) -> [Int] {
        let wanted = max(modelDefault, current)
        guard wanted != modelDefault, !choices.contains(wanted) else { return choices }
        return (choices + [wanted]).sorted()
    }

    /// A stored value read back. Anything that is not a positive whole number of tokens is the
    /// model's own window, because a row nobody can parse must not size a context.
    public static func normalised(_ raw: String?) -> Int {
        guard let raw, let tokens = Int(raw.trimmingCharacters(in: .whitespaces)), tokens > 0 else {
            return modelDefault
        }
        return tokens
    }

    /// What to write for a choice. Nil for the model's own window, so a chat that was set back to
    /// it reads back the same as one nobody ever asked. The same rule fast mode and the output
    /// style are stored under, for the same reason.
    public static func stored(_ tokens: Int) -> String? {
        tokens > 0 ? String(tokens) : nil
    }
}
