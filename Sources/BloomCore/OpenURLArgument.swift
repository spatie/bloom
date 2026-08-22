import Foundation

/// Turns a `--open-url` command line argument into the URL it meant.
///
/// `URL(string:)` refuses a `bloom://` link whose prompt has not been percent encoded: a space or
/// a colon anywhere in the payload returns nil, so `Bloom --open-url "bloom://prompt=fix: the
/// bug&path=..."` silently opened nothing. That guard was the whole failure: no message, no link,
/// and a harness run that looked like the deep link machinery was broken rather than the argument.
///
/// A link that parses as it stands is passed through untouched, so a caller who encoded properly
/// gets exactly the bytes they built. Only when parsing fails is the payload taken as literal
/// text: each key and value is percent encoded whole, which also encodes `%` and `+`, so what was
/// typed is what arrives after the deep link handler's decoding. A caller who half encoded an
/// argument therefore gets the literal reading of it, which is the only honest interpretation of
/// an argument that was not a URL.
public enum OpenURLArgument {
    public static func url(from argument: String) -> URL? {
        // A non-empty scheme is required of the direct parse too: `URL(string: "://x")` succeeds
        // with an empty scheme, and a link no handler can claim is a link that goes nowhere.
        if let direct = URL(string: argument), let scheme = direct.scheme, !scheme.isEmpty {
            return direct
        }
        return repaired(argument)
    }

    /// RFC 3986's unreserved characters. Everything else is percent encoded, `&` and `=` included,
    /// which is why the payload is split into pairs first.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func repaired(_ argument: String) -> URL? {
        guard let separator = argument.range(of: "://") else { return nil }

        let scheme = String(argument[..<separator.lowerBound])
        let validScheme = !scheme.isEmpty
            && scheme.first?.isLetter == true
            && scheme.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }
        guard validScheme else { return nil }

        // The same shape `BloomDeepLink.values(from:)` reads back: pairs on `&`, one `=` each.
        // Encoding key and value separately keeps those two separators the structure and makes
        // every other byte literal.
        let payload = argument[separator.upperBound...]
            .split(separator: "&", omittingEmptySubsequences: false)
            .map { pair in
                pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    .map { piece in
                        String(piece).addingPercentEncoding(withAllowedCharacters: unreserved)
                            ?? String(piece)
                    }
                    .joined(separator: "=")
            }
            .joined(separator: "&")

        return URL(string: scheme + "://" + payload)
    }
}
