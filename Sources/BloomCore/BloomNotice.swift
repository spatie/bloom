import Foundation

/// Something the app did that the user did not ask for and should still know about.
///
/// Not an alert. An alert stops the window and demands a click, which is far too much for "the
/// name moved and the branch did not"; and staying silent about it is the one thing that would
/// leave somebody believing their branch had been renamed when it had not. So: one sentence, in
/// the corner, that goes away by itself.
///
/// It lives in the core rather than beside the view that draws it because everything about it that
/// is a decision is testable: how long it stays, whether it leaves at all, where the fact stops and
/// the reason starts, and which words in it are a machine's rather than a person's. A view is
/// allowed to draw those answers and not to invent them.
public struct BloomNotice: Identifiable, Equatable, Sendable {
    /// How a notice leaves the screen.
    public enum Dismissal: Equatable, Sendable {
        /// It goes on its own once it has been on screen long enough to read, and the user can
        /// still send it early. Everything that is only news is this.
        case afterReading
        /// It stays until the user takes it away.
        ///
        /// For a notice that reports something the user may have to act on later, where reading it
        /// once is not the same as being done with it. There is exactly one today, and the test on
        /// whether a new notice belongs here is whether the user could still need the words in it
        /// after they have looked away: a path they have to go and look at qualifies, a sentence
        /// about what just happened does not.
        case untilDismissed
    }

    public let id = UUID()
    public var message: String
    public var dismissal: Dismissal

    public init(message: String, dismissal: Dismissal = .afterReading) {
        self.message = message
        self.dismissal = dismissal
    }

    /// How long this notice stays, or nothing at all for one that waits to be dismissed.
    public var lifetime: Duration? {
        switch dismissal {
        case .afterReading: NoticeLifetime.reading(message)
        case .untilDismissed: nil
        }
    }

    /// The message split into the part that is drawn large and the part that is drawn small.
    public var text: NoticeText { NoticeText(message) }
}

/// How long a notice has to stay on screen to have been read.
///
/// A rule rather than a constant, because one banner carries both "This workspace is the first to
/// sail the Coral Sea" and a hundred and seventy characters naming two branches, and a length that
/// suits either one is wrong for the other. The banner was a flat twelve seconds, which is a long
/// time to sit and watch for the short message and, with nothing on screen saying how long was
/// left, read as never going away at all.
///
/// The arithmetic is deliberately plain: a beat to notice it, then reading time, clamped.
public enum NoticeLifetime {
    /// The beat before reading starts and the beat after it ends, together.
    ///
    /// The banner appears in the bottom trailing corner, which is where nobody is looking: the eye
    /// is in the composer or the transcript. Something has to be spent on the glance over, and on
    /// not snatching the last word away the instant it is read.
    public static let noticing = Duration.milliseconds(1800)

    /// Two hundred reading units a minute.
    ///
    /// The usual figure for reading prose on a screen to understand it, and it is used here at its
    /// unhurried end on purpose: this is text nobody asked for, read out of the corner of the eye,
    /// while the reason for reading it is that something did not go the way the reader assumed.
    public static let perUnit = Duration.milliseconds(300)

    /// The floor, which the shortest sentence the app can produce still clears comfortably. Under
    /// four seconds a banner that fades in and out is a flicker rather than a message.
    public static let shortest = Duration.seconds(4)

    /// The ceiling. Past about twelve seconds nobody is still reading, they are waiting, and
    /// waiting is what the dismiss button and the hover pause are for.
    public static let longest = Duration.seconds(12)

    /// How long this message needs.
    public static func reading(_ message: String) -> Duration {
        let span = noticing + perUnit * units(in: message)
        return min(max(span, shortest), longest)
    }

    /// The number of reading units in a message.
    ///
    /// A word is one unit, and every further twelve characters of an unbroken token is another. The
    /// second half of that rule is the whole reason this is not a word count: `freekmurze/iyo-sea`
    /// and `freekmurze/fade-animation-feel` are one word each to a splitter and neither of them is
    /// read as one word by a person. An unfamiliar token has no shape to recognise, so it is read
    /// in pieces, and a notice about branch names is mostly made of them. Twelve characters is
    /// about the length of the longest English word anyone reads at a glance.
    public static func units(in message: String) -> Int {
        let chunk = 12
        return message
            .split(whereSeparator: \.isWhitespace)
            .reduce(0) { total, token in
                let letters = token.filter { $0 != "`" }.count
                return total + 1 + max(0, letters - 1) / chunk
            }
    }
}

/// A run of a notice's text, and whether a machine wrote it.
///
/// The distinction is the one the rest of the app already draws: mono is for what a machine said or
/// will run, so a branch name and a path are set in it and a sentence about them is not.
public struct NoticeRun: Equatable, Sendable {
    public var text: String
    public var isMachine: Bool

    public init(text: String, isMachine: Bool) {
        self.text = text
        self.isMachine = isMachine
    }
}

/// A notice's message, taken apart the way it is drawn.
///
/// Every message this banner carries is two sentences, and they are two different things: what
/// Bloom did, and why it could not do the rest of it. Drawn at one size they are a paragraph in a
/// corner, and the fact, which is the part that matters, is the part that gets skimmed. So the
/// split is made here, once, rather than by eye at the point of writing each message.
///
/// The machine's words are marked in the message with backticks, which is what the rest of the app
/// already means by them, and they never reach the screen: they are a mark in the source sentence,
/// not punctuation the reader should see.
public struct NoticeText: Equatable, Sendable {
    /// What Bloom did. Never empty.
    public var fact: [NoticeRun]
    /// Why, when the message has a second sentence. Empty when it does not.
    public var reason: [NoticeRun]

    public init(_ message: String) {
        let (first, rest) = Self.split(message)
        fact = Self.runs(in: first)
        reason = Self.runs(in: rest)
    }

    /// The message with every mark taken out, which is what a screen reader should be handed and
    /// what a copy of the banner should produce.
    public var plain: String {
        let sentences = [fact, reason]
            .filter { !$0.isEmpty }
            .map { $0.map(\.text).joined() }
        return sentences.joined(separator: " ")
    }

    /// Splits at the end of the first sentence.
    ///
    /// A full stop followed by a space, and nothing cleverer, because the alternative is a sentence
    /// tokeniser deciding where a branch name ends. A full stop inside a backticked token is
    /// skipped, so a version number in a path cannot cut a message in half; a full stop with no
    /// space after it is not an end either, which is what keeps `1.2.3` in one piece when nobody
    /// marked it up.
    private static func split(_ message: String) -> (String, String) {
        var inMark = false
        var index = message.startIndex
        while index < message.endIndex {
            let character = message[index]
            if character == "`" { inMark.toggle() }
            let next = message.index(after: index)
            if character == ".", !inMark, next < message.endIndex, message[next] == " " {
                let head = String(message[message.startIndex...index])
                let tail = String(message[message.index(after: next)...])
                // A trailing fragment with nothing in it is not a sentence, so the whole message
                // stays one piece rather than becoming a heading with a blank line under it.
                if !tail.isEmpty { return (head, tail) }
            }
            index = next
        }
        return (message, "")
    }

    /// Backticked spans become machine runs and everything else stays prose. An unclosed backtick
    /// marks nothing: the rest of the sentence is prose, which is the harmless reading of a typo.
    private static func runs(in sentence: String) -> [NoticeRun] {
        guard !sentence.isEmpty else { return [] }
        let pieces = sentence.split(separator: "`", omittingEmptySubsequences: false)
        guard pieces.count % 2 == 1 else {
            return [NoticeRun(text: sentence.replacingOccurrences(of: "`", with: ""), isMachine: false)]
        }
        return pieces.enumerated().compactMap { position, piece in
            guard !piece.isEmpty else { return nil }
            return NoticeRun(text: String(piece), isMachine: position % 2 == 1)
        }
    }
}
