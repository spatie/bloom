import Foundation

/// Which keystroke closes which window.
///
/// **The bug this is written from.** Bloom's Cmd+W is Close Session, and that item sits in the
/// File menu above the standard Close, so `WindowCloseShortcut` moved the standard Close to
/// Shift+Cmd+W to get it out of the way. There is only one standard Close and every window in the
/// app shares it, so moving its key took Cmd+W away from every window at once. Close Session is
/// scoped to the main window and greys out everywhere else, and the comment in `MainWindowFocus`
/// says AppKit then "finds the standard Close underneath": it no longer does, because the standard
/// Close is answering to a different key. About, Discovered Seas, Settings and each project's
/// settings window were all left with a Cmd+W that beeped.
///
/// Escape is the second half and was never wired at all. A plain `NSWindow` does not close on
/// Escape on this platform; only a panel with a cancel button does. Both windows the owner
/// reported are windows you read and then dismiss, and Escape is what a hand reaches for on those.
///
/// **Why a role rather than a list of windows.** Escape means something inside most of Bloom's
/// windows: a composer cancels with it, a terminal sends it, a text field reverts with it. So the
/// question a key monitor has to answer is not "which window is this" but "is there anything in
/// this window that wanted the key". That is the whole of what a role says, and it is why the
/// default is the cautious one: a window nobody has classified gets Cmd+W, which every Mac window
/// has, and never gets Escape.
public enum WindowDismissal {
    /// What was pressed. Named after the keys rather than after an intention, because the
    /// intention is exactly what the table below decides and a name that pre-empted it would be
    /// two rules with one of them written in a case label.
    public enum Stroke: String, Sendable, CaseIterable {
        case escape
        case commandW
        case shiftCommandW
    }

    /// What is in the window, as far as these two keys are concerned.
    public enum Role: String, Sendable, CaseIterable {
        /// The one window with the sidebar, the transcripts and the terminals. Cmd+W is Close
        /// Session here and Escape belongs to whatever is focused, so neither key closes it. Its
        /// own Close is Shift+Cmd+W, which is what Safari and Terminal do in the same position.
        case workspace

        /// A window that is worked in: Settings, a project's settings, the welcome window with a
        /// sign-in terminal inside it. Cmd+W closes it, the way Cmd+W closes a window everywhere
        /// on the Mac. Escape does not: in a text field Escape reverts the edit, and in a terminal
        /// it is a key the program on the other end is waiting for.
        case utility

        /// A window that is read and then dismissed, with no field and no terminal in it: About,
        /// Discovered Seas. Both keys close it.
        case reading
    }

    /// The window a stroke would land on.
    ///
    /// A value rather than the window itself, so the table is a function of four booleans and the
    /// test target, which has no window framework to reach for, can hold every combination still.
    public struct Target: Sendable, Equatable {
        public let role: Role
        /// A window whose style mask has no close button cannot be closed by asking it to. AppKit
        /// still draws the button, so this cannot be read off the screen.
        public let isClosable: Bool
        /// The key window while a sheet is up is the sheet.
        public let isSheet: Bool
        /// And its host, which must not go out from under it.
        public let hasAttachedSheet: Bool

        public init(
            role: Role,
            isClosable: Bool = true,
            isSheet: Bool = false,
            hasAttachedSheet: Bool = false
        ) {
            self.role = role
            self.isClosable = isClosable
            self.isSheet = isSheet
            self.hasAttachedSheet = hasAttachedSheet
        }
    }

    /// True when the stroke should close that window, and therefore also when it should be
    /// swallowed rather than passed on.
    public static func closes(_ stroke: Stroke, _ target: Target) -> Bool {
        guard target.isClosable, !target.isSheet, !target.hasAttachedSheet else { return false }

        switch stroke {
        case .shiftCommandW:
            // The window's own Close, wherever it is pressed. It exists because Cmd+W was taken,
            // so it has to work in the window that took it.
            return true
        case .commandW:
            return target.role != .workspace
        case .escape:
            return target.role == .reading
        }
    }
}
