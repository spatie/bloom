import Foundation

/// The app's own defaults, for the readers that have to scan for a key prefix.
///
/// `UserDefaults.dictionaryRepresentation()` materialises the whole merged search list and bridges
/// every value to Swift. Measured on this Mac: `NSGlobalDomain` holds 7,514 entries and 344KB
/// where Bloom's own domain holds 87, so a scan for one prefix bridged about 7,600 values to find
/// keys among 87. Launch did that four times on the main actor before `isLoaded` was set.
///
/// **Only safe for keys written with `set(_:forKey:)`.** A key supplied through
/// `register(defaults:)` lives in the registration domain, which is not a persistent domain and is
/// not here, so a scan over this would silently miss it. The tab and split prefixes qualify:
/// `SystemDefaults` is the only `register(defaults:)` in the app and it registers three switches.
public enum DefaultsSnapshot {
    /// - Parameter name: the persistent domain, which is the bundle id for `UserDefaults.standard`
    ///   and the suite name for a suite. Nil falls back to the merged representation, which is
    ///   what an unbundled binary gets.
    public static func own(_ defaults: UserDefaults, name: String?) -> [String: Any] {
        // A named domain with nothing written to it answers nil, and that is an empty answer
        // rather than an unanswerable one. Falling back there would take the whole merged list on
        // every launch until the first tab is stored, and would put the registration domain back
        // in the scan, which is the one thing this type exists to keep out.
        guard let name else { return defaults.dictionaryRepresentation() }
        return defaults.persistentDomain(forName: name) ?? [:]
    }
}
