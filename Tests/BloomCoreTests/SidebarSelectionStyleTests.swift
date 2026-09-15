import Testing
@testable import BloomCore

/// The sidebar's selection, which turned solid blue when the owner switched back to Bloom with the
/// list holding the keyboard. The fill must be the same in every state; only the edge may change.
@Suite("How the sidebar draws its selection")
struct SidebarSelectionStyleTests {
    @Test("a row that is not selected draws nothing, whatever has the keyboard")
    func unselected() {
        for hasKeyboard in [false, true] {
            for isKey in [false, true] {
                let style = SidebarSelectionStyle.resolve(
                    isSelected: false, listHasKeyboard: hasKeyboard, windowIsKey: isKey
                )
                #expect(style == .unselected)
                #expect(!style.drawsFill)
                #expect(!style.drawsKeyboardEdge)
            }
        }
    }

    @Test("with the keyboard elsewhere the row rests")
    func keyboardElsewhere() {
        let style = SidebarSelectionStyle.resolve(
            isSelected: true, listHasKeyboard: false, windowIsKey: true
        )
        #expect(style == .resting)
        #expect(style.drawsFill)
        #expect(!style.drawsKeyboardEdge)
    }

    /// The state the owner was in before switching back: the table still first responder, in a
    /// window that was not key. The arrow keys move nothing there, so no edge.
    @Test("a list holding the keyboard in a window that is not key rests")
    func backgroundWindow() {
        let style = SidebarSelectionStyle.resolve(
            isSelected: true, listHasKeyboard: true, windowIsKey: false
        )
        #expect(style == .resting)
    }

    /// The report itself: the window becomes key again with the list holding the keyboard. The row
    /// keeps the fill it had a moment earlier and gains only the edge.
    @Test("switching back keeps the same fill and adds only the edge")
    func switchingBack() {
        let before = SidebarSelectionStyle.resolve(
            isSelected: true, listHasKeyboard: true, windowIsKey: false
        )
        let after = SidebarSelectionStyle.resolve(
            isSelected: true, listHasKeyboard: true, windowIsKey: true
        )
        #expect(after == .keyboard)
        #expect(before.drawsFill == after.drawsFill)
        #expect(after.drawsKeyboardEdge)
    }
}
