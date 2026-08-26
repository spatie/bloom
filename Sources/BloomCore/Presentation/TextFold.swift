import Foundation

/// What the control under a folded block of output says, in both of the directions it goes in.
///
/// A tool result, a code fence, a crash dump and the literal text inside an expanded row are all
/// cut at a cap and all offer a way past it. The four of them said "Show all", "Show all output",
/// "Show everything the agent printed" and "Show all 812 lines": one control, four sentences, in a
/// pane that can show all four of them within a scroll of each other.
///
/// The wording was the smaller half. All four were **one way**. Each set a flag true and offered
/// no path back, so a 400,000 character stderr dump unfolded once stayed unfolded for the life of
/// the row, and everything the reader was scrolling towards moved a screenful further off. A fold
/// that cannot be folded again is not a fold, it is a cut with a button on it.
///
/// The log row in `WorkspaceEventsView` is the fifth wording and it keeps its own, because it says
/// something none of these do: it shows more OF a tail, where these show all of a block. It was
/// also the only one of the five that already came back, which is where the pair below comes from.
public enum TextFold {
    /// - Parameters:
    ///   - isExpanded: whether the block is currently showing everything it has.
    ///   - lines: how many lines there are in all, where the caller has counted them anyway. Worth
    ///     saying when it is known: it is the difference between a fold somebody opens and one
    ///     they think twice about. Nothing else changes with it, so a caller holding a `String`
    ///     rather than an array leaves it off rather than counting for the label's sake.
    public static func title(isExpanded: Bool, lines: Int? = nil) -> String {
        if isExpanded { return "Show less" }
        guard let lines else { return "Show all" }
        return "Show all \(lines.formatted()) \(lines == 1 ? "line" : "lines")"
    }
}
