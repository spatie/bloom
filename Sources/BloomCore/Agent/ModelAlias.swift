import Foundation

/// Translates a model id into something the `claude` CLI accepts.
///
/// Bloom reads Conductor's settings files verbatim so an existing repository needs no new config,
/// and those files use Conductor's own model ids. The CLI does not know them: a machine whose
/// `~/.conductor/settings.toml` said `models.default = "opus-5-1m"` produced a workspace whose
/// very first turn failed with "There's an issue with the selected model (opus-5-1m)". Verified
/// against the real CLI: `opus-5-1m` is rejected, `claude-opus-5[1m]` and `opus` are accepted.
///
/// Every model string reaches the CLI through here, so it does not matter whether it came from a
/// settings file, the Models screen or the composer's picker.
public enum ModelAlias {
    /// The families the CLI names, in the order a longest-match check needs them.
    private static let families = ["opus", "sonnet", "haiku"]

    public static func cliValue(for model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return "opus" }

        // Anything already in the CLI's own namespace is passed through untouched, so a user who
        // knows exactly which build they want is never second guessed.
        if trimmed.hasPrefix("claude-") { return trimmed }
        // The bare family names are the CLI's own shorthand.
        if families.contains(trimmed) { return trimmed }

        guard let family = families.first(where: { trimmed.hasPrefix($0 + "-") }) else {
            // An id in no shape we recognise is handed over as it stands. Guessing would turn a
            // model the CLI might well accept into one it certainly will not.
            return trimmed
        }

        var rest = String(trimmed.dropFirst(family.count + 1))

        // A trailing context-window marker becomes the CLI's bracket suffix.
        var suffix = ""
        for marker in ["-1m", "-200k"] where rest.hasSuffix(marker) {
            suffix = "[" + marker.dropFirst() + "]"
            rest = String(rest.dropLast(marker.count))
            break
        }

        guard !rest.isEmpty, rest.allSatisfy({ $0.isNumber || $0 == "-" }) else {
            return trimmed
        }

        return "claude-\(family)-\(rest)\(suffix)"
    }
}
