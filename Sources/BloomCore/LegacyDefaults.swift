import Foundation

/// Copies the user's settings out of the defaults domain the app had before it was renamed.
///
/// Every `@AppStorage` value in the app lives in the bundle identifier's domain: terminal theme
/// and text sizes, notification switches, inspector and panel geometry, prompt overrides, tab and
/// split layouts, which workspace was last open, which files have been marked viewed. Changing
/// the bundle identifier does not lose any of it, but it does make all of it invisible, which
/// looks exactly like losing it.
///
/// The copy runs once and is recorded in the NEW domain, so it cannot repeat, and it never
/// overwrites a key that already has a value under the new identifier. Those two rules together
/// are what makes it safe to call unconditionally on every launch.
public enum LegacyDefaults {
    public static let legacyDomain = "be.spatie.baton"

    /// Kept in the new domain rather than the old one, because the old one may be read-only to a
    /// future sandboxed build and because the question being answered is "has THIS domain been
    /// filled in yet".
    public static let completionKey = "migration.legacyDefaults"

    public struct Outcome: Sendable, Equatable {
        public let copied: Int
        public let skipped: Int
        /// False when the flag was already set, meaning nothing was read at all.
        public let ran: Bool
    }

    /// Called before anything can read a setting. A key already present in `defaults` is left
    /// alone: the only way one can exist before this runs is that the user set it under the new
    /// identifier, and their newer choice outranks whatever the old domain remembers.
    @discardableResult
    public static func migrate(
        from domain: String = legacyDomain,
        into defaults: UserDefaults = .standard
    ) -> Outcome {
        guard !defaults.bool(forKey: completionKey) else {
            return Outcome(copied: 0, skipped: 0, ran: false)
        }

        // Marked done even when the old domain is empty. A fresh install has nothing to copy and
        // should not pay for reading another domain on every launch forever.
        defer { defaults.set(true, forKey: completionKey) }

        guard let legacy = defaults.persistentDomain(forName: domain) else {
            return Outcome(copied: 0, skipped: 0, ran: true)
        }

        var copied = 0
        var skipped = 0
        for (key, value) in legacy {
            guard key != completionKey else { continue }
            guard defaults.object(forKey: key) == nil else {
                skipped += 1
                continue
            }
            defaults.set(value, forKey: key)
            copied += 1
        }
        return Outcome(copied: copied, skipped: skipped, ran: true)
    }
}
