import Foundation
import BloomCore

/// How a tool call is drawn, worked out once per row rather than once per pass.
///
/// `TranscriptPresenter.present` is a pure function of a call's name and input, and it is not free.
/// For a Codex workspace it starts with `CodexItem.decode`, which parses the whole item out of the
/// call's input; for a `Write` it counts the lines of the entire file the agent wrote. It was being
/// asked from `ToolRowView.body`, which holds the row's own `isHovered`, so the pointer crossing a
/// row ran it twice, and every pass of the transcript's list ran it again for every realised row.
///
/// Keyed on the row's id alone, and that is the same argument `TranscriptEventCache`'s doc makes
/// about payload identity turned the right way up: a stored row's payload is written once and never
/// rewritten, so a presentation derived from it cannot go stale. A row whose payload really did
/// change would be a row nothing else in this transcript could redraw correctly either.
///
/// The cost limit the event cache carries has no equivalent here. A `ToolPresentation` is a glyph
/// name, two short strings and a handful of chips, all of them already truncated to a line, so the
/// count is the whole of what needs bounding. Only the number was wrong.
enum TranscriptPresentationCache {
    /// **Every tool row a long session can hold, rather than a screen of them.**
    ///
    /// It was 256, on the argument that this is "the same figure `TranscriptEventCache` holds".
    /// That figure had already been retired next door, and for a reason that applies here word for
    /// word: the workspace this was measured against holds 1,306 messages, so one scroll from the
    /// bottom of it to the top evicted every entry and recomputed all of them on the way back.
    /// What is recomputed is `TranscriptPresenter.present`, which for a Codex workspace decodes
    /// the whole item out of the call's input and for a `Write` counts the lines of the entire
    /// file the agent wrote.
    ///
    /// A count rather than a cost, unlike the event cache, because the thing being held really is
    /// small and bounded: the strings in a `ToolPresentation` are already cut to one line before
    /// they get here, so eight thousand of them is a couple of megabytes at worst, where eight
    /// thousand payloads would be the transcript itself.
    private static let limit = 8_192

    /// Shared, and safe to share for `TranscriptEventCache`'s reason: `NSCache` does its own
    /// locking, a `ToolPresentationBox` is a `final class` holding one `let` of a `Sendable`
    /// struct, and an `NSNumber` is immutable. `TranscriptPrime` fills this off the main actor
    /// while the table reads it on it.
    nonisolated(unsafe) private static let values: NSCache<NSNumber, ToolPresentationBox> = {
        let cache = NSCache<NSNumber, ToolPresentationBox>()
        cache.countLimit = limit
        return cache
    }()

    /// The worktree is not part of the key, and does not need to be. A row id is a `messages`
    /// rowid, `AUTOINCREMENT` so it is never reused, so it belongs to one workspace for good. The
    /// worktree does move, on `Workspace.restore(to:)`, and a row stripped against the worktree it
    /// actually ran in is the answer we want anyway.
    static func presentation(rowID: Int64, use: AgentToolUse, worktree: String) -> ToolPresentation {
        let key = NSNumber(value: rowID)
        if let cached = values.object(forKey: key) { return cached.value }

        let value = TranscriptPresenter.present(use, worktree: worktree)
        values.setObject(ToolPresentationBox(value), forKey: key)
        return value
    }
}

/// `NSCache` cannot hold a value type. See `TranscriptEventCache`, which keeps its boxes beside it
/// for the same reason.
private final class ToolPresentationBox {
    let value: ToolPresentation

    init(_ value: ToolPresentation) { self.value = value }
}
