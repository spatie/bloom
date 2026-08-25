import AppKit
import BloomCore

/// What came back from a question a page asked.
struct BrowserDialogAnswer {
    /// Whether the reader pressed the affirmative button. `confirm` returns this straight to the
    /// page; `alert` has nothing to return and ignores it.
    var isConfirmed: Bool
    /// What a `prompt` was answered with, or nothing for a cancel and for the other two.
    var text: String?
    /// The reader ticked the box asking this page to stop.
    var isSilenced = false

    /// Nobody was asked, or the question went away before it was answered. It is the answer a
    /// browser gives for a cancel, which is the one a page must always be ready for.
    static let dismissed = BrowserDialogAnswer(isConfirmed: false, text: nil)
}

/// Puts one of a page's questions on screen and waits for it to be answered.
///
/// **A sheet on the window the page is in, and never `runModal`.** That is the rule the rest of
/// this app already follows and the reason is in `PanelPresentation`: `runModal` is not "this
/// window is busy", it is "this process is busy", and a page that asked a question would stop
/// every other workspace's transcript streaming until somebody answered it. A sheet is also what
/// the platform does with a question a document raises, so it hangs off the window the page is in
/// rather than floating in the middle of the screen with no idea which pane it came from.
///
/// **The completion handler is the whole hazard here, and the design is about calling it exactly
/// once.** WebKit gives a page's JavaScript back its answer through a handler that Bloom has to
/// call: never calling it hangs that page for ever with no way back short of closing the tab, and
/// calling it twice raises. Two things hold that here. The delegate methods are written in their
/// `async` spelling, so the compiler resumes the caller exactly once whatever path this returns
/// by, and `dismiss` ends the sheet through AppKit, which runs the same single completion. There
/// is no path that answers a page by hand.
///
/// **If the pane goes away while a question is up**, `BrowserSession.stop` calls `dismiss`, the
/// sheet is ended, and the page is answered as though the reader had pressed Cancel. That is the
/// answer a page is already obliged to handle, and it happens before the web view is let go, so
/// the closing tab never leaves a sheet standing on the window.
@MainActor
final class BrowserDialogPresenter {
    /// The question on screen, if there is one. Held so it can be taken down from outside.
    private var live: (alert: NSAlert, host: NSWindow)?

    /// A field, kept for as long as the prompt it belongs to, because `NSAlert.accessoryView` is
    /// the only reference to it and reading it after the sheet has ended is the whole point.
    private var field: NSTextField?

    func ask(
        _ kind: BrowserDialogs.Kind,
        _ presentation: BrowserDialogs.Presentation,
        over window: NSWindow?
    ) async -> BrowserDialogAnswer {
        // A page in a tab the reader has switched away from has no window to hang a sheet on, and
        // must not get one: a background page that could put a modal sheet over whatever pane is
        // in front would be the loop this whole type is guarding against, with the reader unable
        // to see which page was doing it. Answered as a cancel, which is what every browser does
        // with a dialog from a tab you are not looking at.
        guard let window else { return .dismissed }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = presentation.title
        alert.informativeText = presentation.message
        alert.addButton(withTitle: "OK")
        if kind != .alert { alert.addButton(withTitle: "Cancel") }

        if kind == .prompt {
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
            field.stringValue = presentation.defaultText
            field.isEditable = true
            field.isSelectable = true
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            self.field = field
        }

        if presentation.offersSuppression {
            alert.showsSuppressionButton = true
            // Not "Don't show more dialogs from this page", which is the phrasing two other
            // browsers use, because the reader is not being offered a way to hide something: they
            // are being offered a way to make the page stop, and every question after this one is
            // answered as a cancel rather than swallowed.
            alert.suppressionButton?.title = "Stop this page asking"
        }

        live = (alert, window)
        let response = await alert.beginSheetModal(for: window)
        // Only if it is still ours. `dismiss` clears it, and a later question may have claimed it.
        if live?.alert === alert { live = nil }

        let isConfirmed = response == .alertFirstButtonReturn
        let text = (kind == .prompt && isConfirmed) ? (field?.stringValue ?? "") : nil
        field = nil
        return BrowserDialogAnswer(
            isConfirmed: isConfirmed,
            text: text,
            isSilenced: alert.suppressionButton?.state == .on
        )
    }

    /// Takes the question down and lets the page have its answer, which is what closing the pane
    /// under an open dialog has to do.
    ///
    /// Through `endSheet` rather than by resuming anything of ours, so the one completion AppKit
    /// owns is the one that runs. Calling this with nothing on screen does nothing.
    func dismiss() {
        guard let live else { return }
        self.live = nil
        live.host.endSheet(live.alert.window, returnCode: .cancel)
    }
}
