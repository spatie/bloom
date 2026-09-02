import Foundation

/// The order Claude Code's models are offered in: the most capable first.
///
/// **The menu was in no order at all.** The four names were a list somebody typed, with Fable
/// third, and anything the app was merely *set* to was appended after them by
/// `ComposerOption.adding`, so a chat pinned to `claude-opus-5[1m]` drew its own model at the
/// bottom, under Haiku. A picker whose order says nothing is a picker that has to be read from
/// top to bottom every time rather than reached into.
///
/// **Price is what decides it**, because it is the only published number that ranks these four
/// against each other, and because it is what the owner asked to sort by. Per million tokens, in
/// and out: Fable 5 at $10 and $50, Opus 5 at $5 and $25, Sonnet 5 at $2 and $10, Haiku 4.5 at $1
/// and $5. That order is a fact about the vendor's price list rather than a taste of ours, which
/// is the point: it can be checked, and it is why Fable leads a list that used to open with Opus.
///
/// Four rules, in this order:
///
/// 1. **Family, by price.** Fable, Opus, Sonnet, Haiku. An id naming none of them goes last:
///    Bloom has no way to price something it has never heard of, and guessing would put an
///    unknown id above a model the reader is paying for.
/// 2. **The bare family name first.** `opus` is the CLI's own word for the current Opus, so it
///    outranks any id that names a version, however high that version is.
/// 3. **Version descending** among the ids that name one. `claude-opus-5` above
///    `claude-opus-4-6`, read as numbers rather than as text, for the reason `CodexModelRank`
///    spells out: `5.10` is above `5.9` as a version and below it as a string.
/// 4. **A context-window variant sits under the id it varies.** `claude-opus-5[1m]` is the same
///    model at the same price as `claude-opus-5` with a longer window, so it belongs beside it
///    rather than anywhere its own name would sort it.
///
/// Stable throughout: two ids this cannot tell apart keep the order they arrived in.
public enum ClaudeModelRank {
    /// Most expensive first. The index is the rank, so the order of this array is the decision.
    static let families = ["fable", "opus", "sonnet", "haiku"]

    /// The window markers the CLI takes, widest first. `ModelAlias` writes these, which is why
    /// they are spelled the way they are there.
    static let windows = ["1m", "200k"]

    public static func ordered(_ ids: [String]) -> [String] {
        ids.enumerated()
            .sorted { left, right in
                let a = key(left.element)
                let b = key(right.element)
                if a.family != b.family { return a.family < b.family }
                if a.namesVersion != b.namesVersion { return !a.namesVersion }
                if a.version != b.version { return a.version.isAbove(b.version) }
                if a.window != b.window { return a.window < b.window }
                // The arrival index, which is what makes this stable rather than merely sorted.
                return left.offset < right.offset
            }
            .map(\.element)
    }

    /// Whether an id names one of the families above, which is how a model id says it belongs
    /// to Claude Code rather than to Codex.
    ///
    /// Read off the ranking rather than off a second list of names, because a second list is a
    /// second thing to update: `claude-opus-5[1m]` and `opus-5-1m` are both Opus and neither is in
    /// the picker's four rows, while `gpt-5.6-sol` names no family at all. `DefaultBackend` is
    /// what asks, and what it decides is which CLI a new chat opens on.
    public static func recognises(_ id: String) -> Bool {
        key(id).family < families.count
    }

    struct Key {
        var family: Int
        var namesVersion: Bool
        var version: Version
        var window: Int
    }

    static func key(_ id: String) -> Key {
        let parts = tokens(of: id)
        let family = families.firstIndex { parts.contains($0) } ?? families.count
        let version = version(after: family, in: parts)

        return Key(
            family: family,
            namesVersion: version != nil,
            version: version ?? Version(),
            window: window(in: parts)
        )
    }

    /// The id cut into words, lowercased. Every separator the CLI and the settings files use at
    /// once, so `claude-opus-5[1m]`, `opus-5-1m` and `opus.5` all come apart the same way.
    static func tokens(of id: String) -> [String] {
        id.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// The first `major.minor` after the family's own word, so the 5 in `claude-opus-5` is read
    /// and the 4 in a repository called `bloom-4` never is.
    ///
    /// Nil when the id names no version, which is the bare family name and the case rule 2 is
    /// about. A window marker is not a version part: `1m` is not all digits, so it stops the
    /// read rather than becoming a minor number.
    static func version(after family: Int, in parts: [String]) -> Version? {
        guard family < families.count,
              let start = parts.firstIndex(of: families[family]) else { return nil }

        let rest = parts[parts.index(after: start)...]
        guard let major = rest.first.flatMap(digits) else { return nil }

        let minor = rest.dropFirst().first.flatMap(digits) ?? 0
        return Version(major: major, minor: minor)
    }

    /// Widest window first among the variants of one id, and the plain id before all of them.
    static func window(in parts: [String]) -> Int {
        for (index, marker) in windows.enumerated() where parts.contains(marker) {
            return index + 1
        }
        return 0
    }

    static func digits(_ part: String) -> Int? {
        guard !part.isEmpty, part.allSatisfy(\.isNumber) else { return nil }
        return Int(part)
    }

    /// A version as its parts rather than as one number, for the reason `CodexModelRank.Version`
    /// gives: read as a decimal, `5.10` sorts below `5.9`, and that answer is wrong.
    struct Version: Equatable {
        var major = 0
        var minor = 0

        /// Named rather than `<`, because "above" here means "offered first", and a comparison
        /// operator on a version invites somebody to reach for the wrong end of it.
        func isAbove(_ other: Version) -> Bool {
            major == other.major ? minor > other.minor : major > other.major
        }
    }
}
