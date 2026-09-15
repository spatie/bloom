import Foundation

/// The order Grok's models are offered in: the newest first.
///
/// Version descending, parsed as numbers rather than compared as text, for the same reason
/// `CodexModelRank` gives: `grok-4.10` is above `grok-4.9` as a version and below it as a string.
/// A bare major (`grok-5`) is that major and zero, so a generation that arrives without a minor
/// still leads the list it replaces.
///
/// Ids that do not look like Grok's (`grok-4.6`, `grok-4.5`) go last rather than being guessed
/// into the ranking: Bloom has no way to price something it has never heard of.
public enum GrokModelRank {
    public static func ordered(_ models: [GrokModel]) -> [GrokModel] {
        models.enumerated()
            .sorted { left, right in
                let a = key(left.element.id)
                let b = key(right.element.id)
                if a.version != b.version { return a.version.isAbove(b.version) }
                return left.offset < right.offset
            }
            .map(\.element)
    }

    /// Whether this id is one of Grok's, so a stored `grok-4.6` opens Grok without a fetch.
    ///
    /// The prefix is the vendor's own namespace. Nothing Codex or Claude Code ships starts with
    /// `grok-`, and guessing from a fetch that has not come back yet is how a default used to
    /// park a model on the wrong backend.
    public static func recognises(_ raw: String) -> Bool {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return id == "grok" || id.hasPrefix("grok-") || id.hasPrefix("grok_")
    }

    private struct Key {
        var version: ModelVersion
    }

    private static func key(_ id: String) -> Key {
        Key(version: ModelVersion.parse(fromGrok: id))
    }
}

private struct ModelVersion: Comparable {
    var parts: [Int]

    static func parse(fromGrok id: String) -> ModelVersion {
        let lower = id.lowercased()
        let body = lower.hasPrefix("grok-") ? String(lower.dropFirst(5))
            : lower.hasPrefix("grok_") ? String(lower.dropFirst(5))
            : lower
        let numeric = body.split { !$0.isNumber && $0 != "." }
            .first
            .map(String.init) ?? ""
        let parts = numeric.split(separator: ".").compactMap { Int($0) }
        return ModelVersion(parts: parts)
    }

    func isAbove(_ other: ModelVersion) -> Bool {
        let count = max(parts.count, other.parts.count)
        for index in 0..<count {
            let a = index < parts.count ? parts[index] : 0
            let b = index < other.parts.count ? other.parts[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    static func < (lhs: ModelVersion, rhs: ModelVersion) -> Bool {
        rhs.isAbove(lhs)
    }
}
