import Foundation

/// What the pointer says about the piece of a transcript run it is standing on.
///
/// **The report this exists for: a link in an agent's message kept the arrow.** The prose in a
/// transcript is one text view per paragraph, so a link is a range inside a run rather than a view
/// of its own, and the pointer over it is a hit test rather than a modifier. That hit test is
/// AppKit's and stays there; what it means is here, because the interesting half is the third case
/// rather than the first two.
///
/// The third case is a file chip that stands for the instructions Bloom put into a message rather
/// than for a file. It looks exactly like the chips either side of it and it opens nothing, because
/// the words it stands for are already in the turn under the pointer, so a hand over it would
/// promise a click that does not answer.
public enum TranscriptPointer: Sendable, Hashable {
    /// The pointing hand every link on the platform uses.
    case hand
    /// The I-beam, which is what a run of selectable prose is.
    case text

    /// - Parameters:
    ///   - link: the point is inside an address the app will open.
    ///   - chipThatOpens: the point is on a chip with somewhere to go, which is a file and never
    ///     an injected instruction.
    public static func over(link: Bool, chipThatOpens: Bool) -> TranscriptPointer {
        link || chipThatOpens ? .hand : .text
    }
}
