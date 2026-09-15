import Foundation

/// One address found in a run of text: where it was written, and where it points.
public struct DetectedLink: Sendable, Hashable {
    /// Where it sits in the text it was found in, so a view can style exactly those glyphs and
    /// leave the sentence around them alone.
    public let range: Range<String.Index>

    /// The characters as they were typed. `localhost:3000`, not `http://localhost:3000`: what is
    /// drawn on the line is what the writer put there.
    public let text: String

    /// The same address made absolute, ready for `URL(string:)`. This is the only half that is
    /// ever opened.
    public let url: String

    public init(range: Range<String.Index>, text: String, url: String) {
        self.range = range
        self.text = text
        self.url = url
    }
}

/// Finds the addresses in a run of text, and refuses everything else that looks a bit like one.
///
/// **What it detects.** Two shapes, and only two.
///
/// 1. An explicit `http://` or `https://`, followed by something that could be a host. The scheme
///    is the whole test: the address is trusted because the writer said what it was, not because a
///    table of top level domains was consulted. That is what makes
///    `https://there-there-6.test/settings` a link here while a detector that recognises hosts by
///    their suffix would drop it, and `.test` is not an exotic case in this app: it is where every
///    site served by a local Valet or Herd lives.
/// 2. `localhost` or `127.0.0.1` with a port on it, which is the other everyday local address and
///    the one shape without a scheme worth the risk. `http://` is assumed, because a dev server on
///    a port is almost never speaking TLS and `https://localhost:3000` fails in a way that looks
///    like Bloom's fault.
///
/// **What it deliberately refuses.**
///
/// - A bare host with no scheme: `example.com`, `www.example.com`, `spatie.be`. Recognising those
///   means guessing at where a sentence ends and a domain begins, and the sentences this scans are
///   full of `Package.swift`, `README.md` and `Views/Transcript/TranscriptView.swift`.
/// - `localhost` on its own. In this app's transcripts it is a word in a sentence at least as
///   often as it is somewhere to go.
/// - Mail addresses, bare or `mailto:`. Detecting `name@host` would also detect
///   `git@github.com:spatie/bloom.git`, and turning a git remote into a link in a tool row is a
///   worse bug than the one this fixes.
/// - Any other scheme. `file://`, `x-apple-something://` and whatever else an agent decided to
///   write are text. Only http and https are ever handed to the browser, and the view layer checks
///   again before it opens anything.
/// - Anything glued to the character before it. A match has to start a token: preceded by a
///   letter, a digit, or one of `@ / . _ - + ~ %`, it is part of something longer and is left
///   alone. That is what keeps `user@localhost:2222`, `./localhost:3000` and paths out.
/// - Anything inside a code span or a fenced block, in `links(in:)`. Text set as code is being
///   quoted, not offered.
///
/// Trailing punctuation is left on the sentence rather than swallowed into the address, and a
/// closing bracket is only kept when the address opened one.
public enum LinkScan: Sendable {
    /// Every address in a run of plain text, in the order they were written.
    ///
    /// Code spans and fenced blocks are stepped over. This is for text that is shown as it was
    /// typed, which is what a user turn is; agent prose reaches the same detection through
    /// `MarkdownParser`, where the fence and the backtick have already been taken out of the line.
    public static func links(in text: String) -> [DetectedLink] {
        var found: [DetectedLink] = []
        var isFenced = false

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let opener = line.drop(while: { $0 == " " || $0 == "\t" })
            if opener.hasPrefix("```") || opener.hasPrefix("~~~") {
                isFenced.toggle()
                continue
            }
            guard !isFenced else { continue }
            scan(line, of: text, into: &found)
        }

        return found
    }

    /// One address beginning exactly at `index`, or nothing.
    ///
    /// This is the shape a scanner that is already walking the string wants, and it is how
    /// `MarkdownParser` reaches the same rules from inside its own inline parse.
    public static func link(in text: String, at index: String.Index) -> DetectedLink? {
        guard index < text.endIndex, Self.starters.contains(text[index]) else { return nil }
        guard startsToken(text, at: index) else { return nil }

        let remainder = text[index...]
        guard let opening = opening(remainder) else { return nil }

        var end = index
        while end < text.endIndex, isAddressCharacter(text[end]) {
            end = text.index(after: end)
        }
        end = trimmingTail(text, from: index, to: end)

        guard text.distance(from: index, to: end) >= opening.required else { return nil }
        let written = String(text[index..<end])
        guard let url = absolute(opening.prefix + written) else { return nil }
        return DetectedLink(range: index..<end, text: written, url: url)
    }

    // MARK: Scanning

    /// The only characters a match can begin with, so a line of prose is walked without asking the
    /// rest of these rules about every letter in it.
    private static let starters: Set<Character> = ["h", "H", "l", "L", "1"]

    private static func scan(_ line: Substring, of text: String, into found: inout [DetectedLink]) {
        var index = line.startIndex
        while index < line.endIndex {
            if line[index] == "`" {
                index = skippingCodeSpan(line, from: index)
                continue
            }
            if let link = link(in: text, at: index) {
                found.append(link)
                index = link.range.upperBound
                continue
            }
            index = line.index(after: index)
        }
    }

    /// Steps over a backticked span, or over the opening run alone when nothing closes it.
    private static func skippingCodeSpan(_ line: Substring, from index: String.Index) -> String.Index {
        let count = line[index...].prefix(while: { $0 == "`" }).count
        let afterOpen = line.index(index, offsetBy: count)
        guard afterOpen < line.endIndex else { return line.endIndex }
        let marker = String(repeating: "`", count: count)
        guard let close = line.range(of: marker, range: afterOpen..<line.endIndex) else { return afterOpen }
        return close.upperBound
    }

    // MARK: Rules

    /// Characters that glue a candidate to whatever came before it, so it is part of a longer word
    /// rather than the start of an address.
    private static let glued: Set<Character> = ["@", "/", ".", "_", "-", "+", "~", "%"]

    private static func startsToken(_ text: String, at index: String.Index) -> Bool {
        guard index > text.startIndex else { return true }
        let previous = text[text.index(before: index)]
        if previous.isLetter || previous.isNumber { return false }
        return !glued.contains(previous)
    }

    /// What has to be put in front of the written text to address it, and how many characters the
    /// match has to reach before it is one at all.
    private static func opening(_ remainder: Substring) -> (prefix: String, required: Int)? {
        for scheme in ["https://", "http://"] where matches(remainder, scheme) {
            // A scheme with nothing behind it is not an address.
            guard let host = remainder.dropFirst(scheme.count).first, host.isLetter || host.isNumber else {
                return nil
            }
            return (prefix: "", required: scheme.count + 1)
        }

        for host in ["localhost", "127.0.0.1"] where matches(remainder, host) {
            let rest = remainder.dropFirst(host.count)
            guard rest.first == ":" else { return nil }
            let port = rest.dropFirst().prefix(while: { $0.isASCII && $0.isNumber }).count
            guard port > 0 else { return nil }
            return (prefix: "http://", required: host.count + 1 + port)
        }

        return nil
    }

    /// A case blind prefix test that never asks a substring how long it is: `remainder` is the
    /// whole rest of the paragraph, and counting it at every candidate character would make this
    /// quadratic on a long answer.
    private static func matches(_ remainder: Substring, _ prefix: String) -> Bool {
        let head = remainder.prefix(prefix.count)
        return head.count == prefix.count && String(head).lowercased() == prefix
    }

    /// Characters that in practice wrap an address rather than belong to it: the angle brackets an
    /// autolink is written in, and every shape of quote. An apostrophe is in there because
    /// "https://example.com's page" is a sentence and a path with an apostrophe in it is a
    /// curiosity, so the possessive is worth more than the curiosity.
    private static let wrappers: Set<Character> = [
        "<", ">", "\"", "'", "\u{2018}", "\u{2019}", "\u{201C}", "\u{201D}", "`",
    ]

    /// Where an address stops.
    private static func isAddressCharacter(_ character: Character) -> Bool {
        !character.isWhitespace && !character.isNewline && !wrappers.contains(character)
    }

    /// Punctuation that ends the sentence rather than the address.
    private static let tail: Set<Character> = [".", ",", ";", ":", "!", "?"]

    /// Brackets that are only part of the address when the address opened them, which is what
    /// keeps `(see https://example.com)` and `https://en.wikipedia.org/wiki/Cat_(disambiguation)`
    /// both right.
    private static let brackets: [Character: Character] = [")": "(", "]": "[", "}": "{"]

    private static func trimmingTail(_ text: String, from start: String.Index, to end: String.Index) -> String.Index {
        var end = end
        while end > start {
            let last = text[text.index(before: end)]
            if tail.contains(last) {
                end = text.index(before: end)
                continue
            }
            if let opener = brackets[last] {
                let body = text[start..<end]
                if body.filter({ $0 == opener }).count < body.filter({ $0 == last }).count {
                    end = text.index(before: end)
                    continue
                }
            }
            break
        }
        return end
    }

    // MARK: Addressing

    /// The written address as something `URL` will accept, or nothing at all.
    ///
    /// Foundation's parser is strict about what may appear unescaped, so a path with a space
    /// already escaped passes straight through while one carrying an accented letter is escaped
    /// here first. A candidate that survives neither is left as text: it was never a link.
    private static func absolute(_ raw: String) -> String? {
        if isAddressable(raw) { return raw }
        guard let escaped = raw.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
              isAddressable(escaped) else { return nil }
        return escaped
    }

    private static func isAddressable(_ value: String) -> Bool {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return false }
        guard scheme == "http" || scheme == "https" else { return false }
        guard let host = url.host(), !host.isEmpty else { return false }
        return true
    }
}
