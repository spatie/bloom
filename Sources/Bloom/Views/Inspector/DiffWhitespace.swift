import BloomCore

/// Where the "ignore whitespace" choice lives, so the header bar's toggle and the diff that
/// obeys it cannot drift apart.
enum DiffWhitespaceSetting {
    static let storageKey = "inspector.diffIgnoreWhitespace"
}
