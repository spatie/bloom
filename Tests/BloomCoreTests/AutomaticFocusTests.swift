import Testing
@testable import BloomCore

@Suite("Automatic input focus")
struct AutomaticFocusTests {
    @Test("a background app cannot change the responder in its visible window")
    func backgroundInstance() {
        #expect(!AutomaticFocus.mayUpdateResponder(applicationIsActive: false, windowIsKey: true, windowIsVisible: true))
        #expect(!AutomaticFocus.mayUpdateResponder(applicationIsActive: false, windowIsKey: false, windowIsVisible: true))
    }

    @Test("a sheet or another window keeps input focus")
    func anotherWindow() {
        #expect(!AutomaticFocus.mayUpdateResponder(applicationIsActive: true, windowIsKey: false, windowIsVisible: true))
    }

    @Test("the foreground window and unseen preparation can accept focus")
    func intendedFocus() {
        #expect(AutomaticFocus.mayUpdateResponder(applicationIsActive: true, windowIsKey: true, windowIsVisible: true))
        #expect(AutomaticFocus.mayUpdateResponder(applicationIsActive: false, windowIsKey: false, windowIsVisible: false))
    }
}
