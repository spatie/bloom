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
/// count limit is the whole of what needs bounding.
@MainActor
enum TranscriptPresentationCache {
    /// Comfortably more than a screen of rows, and the same figure `TranscriptEventCache` holds.
    private static let limit = 256

    private static let values: NSCache<NSNumber, ToolPresentationBox> = {
        let cache = NSCache<NSNumber, ToolPresentationBox>()
        cache.countLimit = limit
        return cache
    }()

    static func presentation(rowID: Int64, use: AgentToolUse) -> ToolPresentation {
        let key = NSNumber(value: rowID)
        if let cached = values.object(forKey: key) { return cached.value }

        let value = TranscriptPresenter.present(use)
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
