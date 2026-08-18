import AppKit
import BloomCore

/// The question asked before a session that is mid turn is closed.
///
/// Closing a session stops its agent, and a turn that is stopped halfway is work that has already
/// been paid for and cannot be picked up again, which is exactly the thing quitting asks about in
/// `BloomAppDelegate.confirmQuit`. It is the same shape here for the same reason.
///
/// Its own type because two places close a session, the tab's close button and Cmd+W, and a
/// warning that only one of them asked would be a warning the keyboard walks straight past.
@MainActor
enum CloseSessionAlert {
    /// True when the session may be closed. An idle session is never asked about: a dialog that
    /// appears when there is nothing to lose is a dialog that stops being read.
    static func allowsClosing(_ session: Session, in model: WorkspaceModel) -> Bool {
        guard model.isRunning(session) else { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        let name = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.messageText = name.isEmpty
            ? "This session is still working"
            : "\(name) is still working"
        alert.informativeText = """
            Closing it stops the agent. The turn it is in the middle of will not be finished, and \
            it cannot be resumed.
            """

        alert.addButton(withTitle: "Close anyway")
        alert.addButton(withTitle: "Keep working")
        // So Return keeps the session rather than ending it: the destructive answer should cost a
        // deliberate click, not the key your hand is already on.
        alert.buttons.last?.keyEquivalent = "\r"
        alert.buttons.first?.keyEquivalent = ""

        return alert.runModal() == .alertFirstButtonReturn
    }
}
