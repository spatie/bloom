import Foundation

/// How wide a run of transcript prose drawn by AppKit is laid out, and what size it then reports.
///
/// The prose in a transcript is drawn two ways. Most paragraphs are a SwiftUI `Text`, and a
/// paragraph carrying a link is an `NSTextView`, because a link inside a selectable `Text` is
/// decoration rather than a link. Only the second one has to answer the layout system's questions
/// itself, and answering them is arithmetic rather than drawing, so it is here rather than in the
/// view: a decision taken inside a view is a decision nothing can test.
///
/// ## The question that was being answered with a shrug
///
/// SwiftUI proposes a width of nothing at all when it wants a view's IDEAL size, and it does that
/// on this exact path. Measured on a probe of the real hierarchy: put `.textSelection(.enabled)`
/// around a markdown block, which is what `ProseRowView` does, and every run inside it is measured
/// once with no width. The view used to answer "I cannot say" to that, and what SwiftUI does with
/// that answer is not what the name suggests. It does not fall back to the view's fitting size,
/// which for a hand-built TextKit 1 stack is zero by zero. It fills the proposal's width and gives
/// the view a SINGLE LINE of height: a paragraph needing 592 by 35 was placed at 592 by 16 with
/// two thirds of it cut off.
///
/// So there is no proposal this view should decline to measure. An unspecified or an infinite
/// width is a question about the ideal size, and the ideal size of a run of text is the run
/// unwrapped. A width of zero is a question about the narrowest the run can be, and the answer is
/// its widest unbreakable word, which is what laying out in a hair's width measures.
///
/// ## And a run with words in it never reports nothing
///
/// The last rule here has no measurement behind it and is a floor rather than a finding. A row
/// that reports no width or no height draws nothing at all, and because a list marker is drawn
/// separately from the line beside it, what the reader gets is a numbered list with "1." on its
/// own and the sentence missing. That is a report we have from a real session and could not
/// reproduce. Whatever the cause turns out to be, this function is one of the places it would have
/// to pass through, and a run holding glyphs coming back with a zero in it is wrong however it got
/// there.
///
/// ## And the floor falls back to the room it was offered, never to `idealWidth`
///
/// The floor used to fall back to the width the run had just been LAID OUT at, which for a
/// question about the ideal size is `idealWidth`: a hundred thousand points, chosen so that
/// nothing wraps in it. That is a scratch measure, not a size, and it was reachable. A run whose
/// glyphs draw no ink at all is the ordinary way in, and there is nothing exotic about one: a
/// paragraph of nothing but line breaks lays out real line fragments, every one of them zero
/// points wide, so `widestLine` is zero while `hasGlyphs` is true. Measured on the real TextKit 1
/// stack, "\n" answered 100000 by 32 to a question about its ideal size, and every other
/// ink-free run answered the same. A row a hundred thousand points wide is not a smaller failure
/// than a blank row.
///
/// So the fallback is the room the run was offered, and a hair's width when it was offered none.
/// Nothing here can report a width the layout system did not first name.
public enum TranscriptTextMeasure {
    /// What "no width was proposed" is laid out at.
    ///
    /// Wide enough that nothing a transcript ever holds wraps inside it, which is what an ideal
    /// size means for a run of text, and finite so that every other rule here has a real number to
    /// fall back on.
    public static let idealWidth: Double = 100_000

    /// The narrowest a run is ever laid out at.
    ///
    /// A proposal of zero still has to be answered, and a container of zero lays out nothing at
    /// all. A hair's width lays out one word per line, so the widest line is the widest word,
    /// which is the minimum width the layout system is asking about.
    public static let floorWidth: Double = 1

    /// The size a run reports, which is the whole of this type's answer.
    public struct Size: Equatable, Sendable {
        public var width: Double
        public var height: Double

        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }
    }

    /// The width to lay the run out at, given whatever the layout system proposed.
    ///
    /// - Parameter proposed: the proposed width, or nothing when the ideal size is being asked
    ///   for. An infinite proposal is the same question by another name.
    public static func layoutWidth(proposed: Double?) -> Double {
        guard let proposed, proposed.isFinite else { return idealWidth }
        return max(proposed, floorWidth)
    }

    /// The size to report back, from what the lay out came back with.
    ///
    /// - Parameters:
    ///   - widestLine: the widest line fragment's used rectangle. **Not the used rectangle of the
    ///     whole container**, which answers the container's width for every string there is: at a
    ///     container of 456, "continue" and a four line paragraph both say 456, and a measure that
    ///     existed to make a short bubble short never made one. See `TranscriptTextView`.
    ///   - usedHeight: the height of the whole lay out, which `usedRect` is right about and which
    ///     counts the extra line fragment a trailing newline leaves behind.
    ///   - proposed: the width that was proposed, unchanged. A finite one caps the answer, because
    ///     a run may not report itself wider than the room it was offered, and it is also what a
    ///     run that measured no ink falls back on.
    ///   - lineHeight: one line of this run's font, which a run that measured no height falls
    ///     back on.
    ///   - hasGlyphs: whether the run holds anything at all. An empty run is the one thing allowed
    ///     to report nothing, and it must, or an empty paragraph would take a line of space.
    public static func size(
        widestLine: Double,
        usedHeight: Double,
        proposed: Double?,
        lineHeight: Double,
        hasGlyphs: Bool
    ) -> Size {
        guard hasGlyphs else { return Size(width: 0, height: 0) }

        var width = widestLine.rounded(.up)
        if let proposed, proposed.isFinite, proposed > 0 {
            width = min(width, proposed)
        }
        // See the head of this type. A run with glyphs in it never reports nothing, and it never
        // reports the scratch width an ideal size is measured in either.
        if !(width > 0) { width = room(offered: proposed) }

        var height = usedHeight.rounded(.up)
        if !(height > 0) { height = max(lineHeight.rounded(.up), floorWidth) }

        return Size(width: width, height: height)
    }

    /// The room a proposal offered, or a hair's width when it offered none.
    ///
    /// The only thing a run that measured nothing is allowed to report itself as. See the head of
    /// this type for what it used to report instead.
    private static func room(offered proposed: Double?) -> Double {
        guard let proposed, proposed.isFinite, proposed > 0 else { return floorWidth }
        return proposed
    }
}
