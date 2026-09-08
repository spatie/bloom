import Foundation

/// One control in the bar above an open file: the word on it, and the sentence that explains it.
///
/// Two strings rather than one because they answer two different questions. The title is what the
/// control says while nobody is pointing at it, so it is a word or two and it has to fit in a row
/// beside five others. The hint is what the bar says the moment somebody does point at it, so it
/// is a sentence and it may name the file.
public struct FileBarControl: Equatable, Sendable {
    /// The word on the control, for the arrangement wide enough to carry words.
    public let title: String
    /// The sentence the bar shows while the pointer is over it, and the tooltip text besides.
    public let hint: String

    public init(title: String, hint: String) {
        self.title = title
        self.hint = hint
    }
}

/// What every control in the bar above an open file is called, and what each of them does said in
/// a sentence.
///
/// # Why this is copy in the core rather than strings in the bar
///
/// Reported by somebody reading a Bloom diff for the first time: the row of glyphs above it is
/// ambiguous, and the only thing that says what any of them are is a tooltip that takes about a
/// second and a half to arrive. That is two complaints and they have two different answers.
///
/// The first is that the controls should say what they are. `FileHeaderBar` now draws them with
/// their words wherever the bar is wide enough to hold the words, and falls back to the glyphs
/// only when it is not, so the common case needs no hover at all.
///
/// The second is the delay, and the delay is not ours to change: the tooltip interval is a system
/// setting that belongs to the person using the Mac and applies to every application on it, so
/// writing to it to make one bar feel quicker would be reaching outside this app to fix something
/// inside it. What the bar does instead is show the sentence itself, in its own row, the moment
/// the pointer lands. It is not a tooltip, so it has no delay to shorten.
///
/// Both answers are copy, and copy a view builds inline is copy nothing can test. There are three
/// bars over a file in this window and each of them was writing its own strings, which is how the
/// wide row came to say "Show the diff as one column or side by side" while its own overflow menu
/// offered the same choice as "Unified" and "Side by side": two spellings of one control, a
/// hundred lines apart in one file, and nothing able to notice. Written once here, they are also
/// the thing a test can hold, which is what `FileBarControlsTests` does.
public enum FileBarControls {
    /// Throwing away the changes to this file, which is the only control in the bar that destroys
    /// anything and is drawn as such.
    public static func revert(filename: String) -> FileBarControl {
        FileBarControl(
            title: "Revert file",
            hint: "Throw away the changes to \(filename) and put it back the way git has it"
        )
    }

    /// Unified or side by side. One choice between two values, so the two titles are the segments
    /// and the hint belongs to the picker rather than to either of them.
    public static let unified = "Unified"
    public static let sideBySide = "Side by side"

    public static let layout = FileBarControl(
        title: "Layout",
        hint: "Show the diff as one column, or the old and the new side by side"
    )

    /// Hiding the changes that are only indentation.
    ///
    /// The hint says what pressing it will do rather than what state it is in, because the fill
    /// under the control already says the state and a sentence that only repeats it wastes the one
    /// line the bar has.
    public static func whitespace(ignoring: Bool) -> FileBarControl {
        FileBarControl(
            title: "Ignore whitespace",
            hint: ignoring
                ? "Show the changes that are only whitespace again"
                : "Hide the changes that are only whitespace, such as reindenting"
        )
    }

    /// The clipboard. What it copies depends on which of the two panes is open, which is the
    /// conditional that used to live in the bar and used to disagree with the bar's own menu.
    ///
    /// **`didCopy` changes the hint and never the title**, and that is a layout decision rather
    /// than a wording one. The bar's controls sit against its trailing edge, so a button whose
    /// word grows or shrinks as it is pressed drags everything to the left of it along while the
    /// pointer is still resting on the thing that moved. The press is confirmed by the glyph
    /// flashing to a tick and by this sentence, which is already on screen: the pointer is on the
    /// button at the moment of the press, so the hint is showing.
    public static func copy(mode: FileViewMode, didCopy: Bool = false) -> FileBarControl {
        let title = mode == .edit ? "Copy file" : "Copy diff"
        let subject = mode == .edit ? "file" : "diff"
        return FileBarControl(
            title: title,
            hint: didCopy
                ? "The \(subject) is on the clipboard"
                : "Copy this \(subject) to the clipboard"
        )
    }

    /// Handing the diff to whatever the Mac can send things to.
    ///
    /// **No longer a control in the bar**, and that is the whole point of it being here. It was a
    /// share glyph sitting next to the copy glyph, which is two ways to do nearly the same thing
    /// given equal weight in a row that was already too full, and it was reported as clutter. The
    /// route is kept, one press further away, in the bar's own menu.
    public static func share(filename: String) -> FileBarControl {
        FileBarControl(title: "Share the diff", hint: "Send the diff for \(filename) somewhere else")
    }

    /// Everything that is not worth a control of its own.
    public static let more = FileBarControl(
        title: "More",
        hint: "More things to do with this file"
    )

    /// Reading the file or editing it here. The title is the picker's own name, which is hidden
    /// on screen and read by VoiceOver; what the segments show is `FileViewMode`'s raw values.
    public static func mode(filename: String, isEditable: Bool) -> FileBarControl {
        FileBarControl(
            title: "File view",
            hint: isEditable
                ? "Switch between what changed and the whole of \(filename), which you can edit here"
                : "\(filename) cannot be edited here"
        )
    }
}
