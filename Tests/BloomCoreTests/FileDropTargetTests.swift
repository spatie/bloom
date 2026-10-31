import CoreGraphics
import Testing
@testable import BloomCore

@Suite("FileDropTarget")
struct FileDropTargetTests {
    private static let mainChat = SessionID("main")
    private static let sideChat = SessionID("side")
    private static let card = CGRect(x: 100, y: 200, width: 400, height: 300)

    private func resolve(
        focused: SessionID? = FileDropTargetTests.mainChat,
        sideConversation: SessionID? = FileDropTargetTests.sideChat,
        at point: CGPoint?
    ) -> SessionID? {
        FileDropTarget.resolve(
            focused: focused, sideConversation: sideConversation, cardFrame: Self.card, at: point
        )
    }

    @Test("A drop over the card goes to the side conversation")
    func overCard() {
        #expect(resolve(at: CGPoint(x: 300, y: 350)) == Self.sideChat)
    }

    @Test("A drop beside the card goes to the focused chat, however long the card stays open")
    func besideCard() {
        #expect(resolve(at: CGPoint(x: 50, y: 350)) == Self.mainChat)
        #expect(resolve(at: CGPoint(x: 300, y: 600)) == Self.mainChat)
    }

    @Test("With no card open every drop goes to the focused chat")
    func noCard() {
        #expect(resolve(sideConversation: nil, at: CGPoint(x: 300, y: 350)) == Self.mainChat)
    }

    @Test("A drop with no pointer, which is the sidebar, never reaches the card")
    func noPointer() {
        #expect(resolve(at: nil) == Self.mainChat)
    }

    @Test("Nothing is focused, nothing takes the drop")
    func nothingFocused() {
        #expect(resolve(focused: nil, at: CGPoint(x: 300, y: 350)) == nil)
    }
}
