import Foundation

/// The order Codex's models are offered in: the most capable first.
///
/// **The list used to be "the account's default, then whatever order the server sent".** That is a
/// defensible rule and it is not the one the owner asked for. It also is not stable: the default
/// is an account setting, so the same list could come out in two orders on two machines, and a
/// picker whose order depends on somebody's settings is a picker you have to read every time
/// rather than reach into.
///
/// So the order is derived from the names, which is the only thing here that says anything about
/// capability. Three rules, in this order:
///
/// 1. **Version, descending.** `gpt-5.6` above `gpt-5.5` above `gpt-5.4`. Parsed as numbers rather
///    than compared as text, because `gpt-5.10` sorts below `gpt-5.9` as a string and above it as
///    a version, and the string answer is wrong. A major with no minor after it is that major and
///    zero, which is how `gpt-6-astra` came to lead the list the day it appeared without anything
///    here being told about it. That is the case worth protecting: read a bare major as no version
///    at all and the newest model on the account is offered below every model it replaces.
/// 2. **Full models above cut-down ones at the same version.** `gpt-5.4` above `gpt-5.4-mini`.
///    The suffixes are the vendor's own words for a smaller model, and a smaller model is the
///    thing you pick on purpose rather than the thing you are offered first.
/// 3. **Otherwise the order the server gave.** Three variants of one version (Sol, Terra, Luna)
///    carry nothing in their names that ranks them, and inventing a rank would be inventing a
///    fact. The sort is stable, so they keep the vendor's order among themselves.
///
/// The account's default is no longer moved to the top. It is still marked as the default
/// wherever a picker chooses to say so; what it stopped doing is jumping the queue.
public enum CodexModelRank {
    /// The suffixes that name a reduced model. Matched on a word boundary, so a model whose name
    /// merely contains these letters is not demoted by accident.
    static let reduced = ["mini", "nano", "spark", "lite", "small"]

    /// Most capable first. Stable: models this cannot tell apart keep the order they arrived in.
    public static func ordered(_ models: [CodexModel]) -> [CodexModel] {
        models.enumerated()
            .sorted { left, right in
                let a = key(left.element)
                let b = key(right.element)
                if a.version != b.version { return a.version.isAbove(b.version) }
                if a.isReduced != b.isReduced { return !a.isReduced }
                // The arrival index, which is what makes this stable rather than merely sorted.
                return left.offset < right.offset
            }
            .map(\.element)
    }

    static func key(_ model: CodexModel) -> (version: Version, isReduced: Bool) {
        (version(of: model.id), isReduced(model.id))
    }

    /// A version as its parts rather than as one number, which is the whole point.
    ///
    /// Read as a decimal, `5.10` is 5.1 and sorts *below* `5.9`. That is the bug this type
    /// exists to make impossible: the components are integers and are compared as integers, so
    /// the tenth minor release of 5 is above the ninth.
    struct Version: Equatable {
        var major = 0
        var minor = 0

        /// Named rather than `<`, because "above" here means "offered first", and a comparison
        /// operator on a version invites somebody to reach for the wrong end of it.
        func isAbove(_ other: Version) -> Bool {
            major == other.major ? minor > other.minor : major > other.major
        }
    }

    /// The first `major.minor` in the id. Zero for an id carrying no version at all, which puts it
    /// below everything that names one rather than above it.
    static func version(of id: String) -> Version {
        let digits = id.lowercased().drop { !$0.isNumber }
        var seenDot = false
        let text = digits.prefix {
            if $0.isNumber { return true }
            if $0 == ".", !seenDot { seenDot = true; return true }
            return false
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return Version(
            major: parts.first.flatMap { Int($0) } ?? 0,
            minor: parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        )
    }

    static func isReduced(_ id: String) -> Bool {
        let words = id.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return words.contains { reduced.contains($0) }
    }
}
