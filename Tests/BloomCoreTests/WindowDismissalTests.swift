import Testing
@testable import BloomCore

@Suite("Window dismissal")
struct WindowDismissalTests {
    private func target(
        _ role: WindowDismissal.Role,
        closable: Bool = true,
        sheet: Bool = false,
        hasSheet: Bool = false
    ) -> WindowDismissal.Target {
        WindowDismissal.Target(
            role: role, isClosable: closable, isSheet: sheet, hasAttachedSheet: hasSheet
        )
    }

    @Test("Escape closes a window that is only read")
    func escapeClosesReading() {
        #expect(WindowDismissal.closes(.escape, target(.reading)))
    }

    @Test("Escape is left alone in a window with fields or a terminal in it")
    func escapeSpareUtility() {
        #expect(!WindowDismissal.closes(.escape, target(.utility)))
    }

    @Test("Escape never closes the workspace window, where it cancels what is focused")
    func escapeSparesWorkspace() {
        #expect(!WindowDismissal.closes(.escape, target(.workspace)))
    }

    @Test("Cmd+W closes every window but the one where it is Close Session")
    func commandWClosesSecondaryWindows() {
        #expect(WindowDismissal.closes(.commandW, target(.reading)))
        #expect(WindowDismissal.closes(.commandW, target(.utility)))
        #expect(!WindowDismissal.closes(.commandW, target(.workspace)))
    }

    @Test("Shift+Cmd+W closes any window, the workspace one included")
    func shiftCommandWClosesAnything() {
        for role in WindowDismissal.Role.allCases {
            #expect(WindowDismissal.closes(.shiftCommandW, target(role)))
        }
    }

    @Test("A window with no close button in its style mask is not asked to close")
    func sparesUnclosableWindows() {
        for stroke in WindowDismissal.Stroke.allCases {
            #expect(!WindowDismissal.closes(stroke, target(.reading, closable: false)))
        }
    }

    @Test("A sheet is not a window to close, and neither is the host under it")
    func sparesSheets() {
        for stroke in WindowDismissal.Stroke.allCases {
            #expect(!WindowDismissal.closes(stroke, target(.reading, sheet: true)))
            #expect(!WindowDismissal.closes(stroke, target(.utility, hasSheet: true)))
        }
    }
}
