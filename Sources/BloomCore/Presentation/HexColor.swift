import Foundation

/// One reading of a hex colour, for everything in the app that stores a colour as text.
///
/// There were two. Ghostty's config parser had this one, which validates every character, accepts
/// the hash as optional and expands the three digit form. The palette had a second, one line long,
/// which handed the whole string to `UInt32(_:radix:)` and fell back to a hard-coded blue when
/// that returned nil. The second one read `abc` as `0x000ABC`, a near black, where every other
/// tool on the machine reads it as `#AABBCC`; it also accepted a stray space, an eight digit
/// string and `0x` prefixed text as colours nobody wrote.
///
/// Three opaque channels rather than a colour type, because BloomCore has no UI and the callers
/// want different colour types out of the same bytes.
public struct HexColor: Sendable, Hashable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// `#rrggbb`, `rrggbb`, `#rgb` or `rgb`, with surrounding whitespace allowed.
    ///
    /// Anything else is nil rather than a guess. A caller that has a colour to fall back on keeps
    /// it, which is what leaves an unreadable value in a config or a database showing the app's
    /// own colour instead of something wrong.
    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }

        let digits = text.compactMap(\.hexDigitValue)
        guard digits.count == text.count else { return nil }

        switch digits.count {
        // Each digit is doubled, so `#abc` is `#aabbcc`.
        case 3:
            self.init(
                red: UInt8(digits[0] * 17),
                green: UInt8(digits[1] * 17),
                blue: UInt8(digits[2] * 17)
            )
        case 6:
            self.init(
                red: UInt8(digits[0] * 16 + digits[1]),
                green: UInt8(digits[2] * 16 + digits[3]),
                blue: UInt8(digits[4] * 16 + digits[5])
            )
        default:
            return nil
        }
    }
}
