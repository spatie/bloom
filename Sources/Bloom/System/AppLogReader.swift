import Foundation
import OSLog
import BloomCore

/// Reads back what this running copy of Bloom told its own log, so a feedback report can carry it.
///
/// **This process, and no other.** The scope is `.currentProcessIdentifier`, which is the only
/// scope a sandboxed, unprivileged app may read at all, and it is also exactly the right one: what
/// belongs in a bug report is what this launch of Bloom did, not what the machine did. Nothing
/// here can see another application's log, the system's log, or a previous run of Bloom.
///
/// **Bloom's own lines, and no framework's.** The predicate keeps only entries whose subsystem is
/// Bloom's, so the URL loading system, AppKit, Sparkle and everything else that logs from inside
/// this process is left out. That is not tidiness: those lines are written by code that never
/// agreed to be quoted, and they are where a URL with a token in it would come from.
///
/// What is done with the lines afterwards, which is where the caps and the scrubbing are, is
/// `AppLogExcerpt` in the core. This file only fetches.
enum AppLogReader {
    /// The subsystem `Log` files everything under.
    ///
    /// The same expression `Log.subsystem` uses, restated because that one is private to the
    /// enum. If these two ever disagree the logs option quietly returns nothing, which is why it
    /// is written the same way round rather than as a literal.
    static let subsystem = Bundle.main.bundleIdentifier ?? "be.spatie.bloom"

    /// The recent lines, oldest first, capped at `limit` from the newest end.
    ///
    /// `nonisolated` and never called from the main actor: `getEntries` walks a store and decodes
    /// every entry it passes, and the number of them is whatever this session happened to produce.
    /// Every caller wraps it in a detached task.
    nonisolated static func recent(
        window: TimeInterval = AppLogExcerpt.window,
        limit: Int = AppLogExcerpt.maxEntries,
        now: Date = Date()
    ) -> [AppLogExcerpt.Entry] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return [] }

        let since = now.addingTimeInterval(-window)
        let predicate = NSPredicate(format: "subsystem == %@", subsystem)
        guard let entries = try? store.getEntries(at: store.position(date: since), matching: predicate) else {
            return []
        }

        var found: [AppLogExcerpt.Entry] = []
        for case let entry as OSLogEntryLog in entries {
            // The position is a hint rather than a filter: it seeks the store to roughly the right
            // place, and an entry from before the window can still come back through it.
            guard entry.date >= since else { continue }

            found.append(
                AppLogExcerpt.Entry(
                    date: entry.date,
                    category: entry.category,
                    message: entry.composedMessage
                )
            )
            // A rolling window, so a session that logged ten thousand lines costs the last two
            // hundred of them rather than all ten thousand held at once.
            if found.count > limit { found.removeFirst() }
        }
        return found
    }
}
