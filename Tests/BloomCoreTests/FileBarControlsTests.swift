import Testing
import Foundation
@testable import BloomCore

/// The bar above a diff was reported as a row of glyphs nobody could read, with a system tooltip
/// a second and a half away as the only explanation. The fix is copy: a word on every control and
/// a sentence the bar shows the instant the pointer lands. Copy a view builds inline is copy
/// nothing can hold, so it is `FileBarControls` and it is held here.
@Suite("The controls above a file")
struct FileBarControlsTests {
    /// Every control the bar can draw, for the sweeps below.
    private var all: [FileBarControl] {
        [
            FileBarControls.revert(filename: "Handler.php"),
            FileBarControls.layout,
            FileBarControls.whitespace(ignoring: false),
            FileBarControls.whitespace(ignoring: true),
            FileBarControls.copy(mode: .diff),
            FileBarControls.copy(mode: .edit),
            FileBarControls.copy(mode: .diff, didCopy: true),
            FileBarControls.share(filename: "Handler.php"),
            FileBarControls.more,
            FileBarControls.mode(filename: "Handler.php", isEditable: true),
            FileBarControls.mode(filename: "Handler.php", isEditable: false),
        ]
    }

    @Test("every control has a word and a sentence")
    func nothingIsBlank() {
        for control in all {
            #expect(!control.title.isEmpty)
            #expect(!control.hint.isEmpty)
        }
    }

    @Test("the word is a word and the sentence is longer than it")
    func aTitleIsShortAndAHintExplains() {
        for control in all {
            // Short enough to sit in a row of six controls above a diff. "Ignore whitespace" is
            // the longest of them at seventeen.
            #expect(control.title.count <= 20)
            // A hint that is no longer than the word on the control is a hint that adds nothing,
            // which is what a tooltip repeating its own label is.
            #expect(control.hint.count > control.title.count)
        }
    }

    @Test("nothing is titled with a sentence and nothing is hinted with a fragment")
    func theRegisterIsRight() {
        for control in all {
            #expect(!control.title.hasSuffix("."))
            #expect(!control.hint.hasSuffix("."))
            #expect(control.title.first?.isUppercase == true)
            #expect(control.hint.first?.isUppercase == true)
        }
    }

    // MARK: - What each of them says

    @Test("revert names the file it would throw away")
    func revertNamesTheFile() {
        let control = FileBarControls.revert(filename: "Handler.php")

        #expect(control.title == "Revert file")
        #expect(control.hint.contains("Handler.php"))
    }

    @Test("copy says which of the two panes it would copy")
    func copyFollowsTheModeItIsIn() {
        // The one string that used to be built inline in the bar, and the one that has to follow
        // the pane: a Copy button offering the diff while the editor is open is offering something
        // that is not on screen.
        #expect(FileBarControls.copy(mode: .diff).title == "Copy diff")
        #expect(FileBarControls.copy(mode: .edit).title == "Copy file")
        #expect(FileBarControls.copy(mode: .diff).hint.contains("diff"))
        #expect(FileBarControls.copy(mode: .edit).hint.contains("file"))
    }

    @Test("the flash after a press changes the sentence and never the word")
    func copyKeepsItsWidthWhileItFlashes() {
        // The controls sit against the trailing edge of the bar, so a button whose word changes
        // length as it is pressed drags every control left of it along under the pointer that has
        // just pressed it. The tick and this sentence are what confirm the press instead.
        for mode in FileViewMode.allCases {
            let resting = FileBarControls.copy(mode: mode)
            let flashed = FileBarControls.copy(mode: mode, didCopy: true)

            #expect(flashed.title == resting.title)
            #expect(flashed.hint != resting.hint)
            #expect(flashed.hint.contains("clipboard"))
        }
    }

    @Test("the whitespace toggle says what pressing it will do, not what state it is in")
    func whitespaceSaysWhatWillHappen() {
        let hiding = FileBarControls.whitespace(ignoring: true)
        let showing = FileBarControls.whitespace(ignoring: false)

        // One word on the control whichever way it is set, because the fill under a toggle is
        // what says which way that is, and a label that changed would move the row.
        #expect(hiding.title == showing.title)
        #expect(hiding.hint != showing.hint)
        #expect(showing.hint.hasPrefix("Hide"))
        #expect(hiding.hint.hasPrefix("Show"))
    }

    @Test("a file that cannot be edited says so instead of describing the switch")
    func theModePickerAnswersWhyItIsOff() {
        let editable = FileBarControls.mode(filename: "logo.png", isEditable: true)
        let locked = FileBarControls.mode(filename: "logo.png", isEditable: false)

        #expect(locked.hint == "logo.png cannot be edited here")
        #expect(editable.hint != locked.hint)
        #expect(editable.hint.contains("logo.png"))
    }

    @Test("the two layout segments are the words the overflow menu uses")
    func oneSpellingOfOneChoice() {
        // The bar draws this as a segmented control and its own overflow menu draws it as an
        // inline Picker, a hundred lines apart in one file. Two spellings of one choice is what
        // putting the strings here is for.
        #expect(FileBarControls.unified == "Unified")
        #expect(FileBarControls.sideBySide == "Side by side")
        #expect(FileBarControls.unified != FileBarControls.sideBySide)
    }

    @Test("share still has copy, because it is still a route")
    func shareSurvivesLosingItsButton() {
        // The share button came out of the bar as clutter: a second glyph beside Copy doing nearly
        // the same thing. What must not happen is the route going with it, so the menu item that
        // replaces it is named here and named in one place.
        let control = FileBarControls.share(filename: "Handler.php")

        #expect(control.title == "Share the diff")
        #expect(control.hint.contains("Handler.php"))
    }
}
