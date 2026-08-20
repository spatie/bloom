import SwiftUI
import BloomCore

/// Which of the two Help menu sheets is up, and what has been typed into either of them.
///
/// **The drafts live here rather than in the sheets**, and that is the whole reason this type
/// exists. A sheet's `@State` is gone the moment the sheet is dismissed, so a report somebody had
/// half written and closed by accident, or closed because the send failed and they wanted to look
/// something up, would be gone with it. Held here they last as long as the app does: Escape,
/// reopen, and the paragraph is still there with its attachments and its checkbox.
///
/// A draft is cleared only by a send that actually worked. Nothing else empties it, including a
/// refusal from the server: the one rule the whole sending path is built around is that a failure
/// costs a press of a button and never a paragraph.
@MainActor
@Observable
final class FeedbackPresenter {
    static let shared = FeedbackPresenter()

    enum Sheet: String, Identifiable, CaseIterable {
        case report
        case prompt

        var id: String { rawValue }
    }

    /// Non-nil while one of the two is up. Settable so a `.sheet(item:)` binding can close it.
    var sheet: Sheet?

    // MARK: - The feedback draft

    var message = ""
    /// Off to start with, every time, and never remembered as on. See `FeedbackSheet`.
    var includesLogs = false
    /// The excerpt as it was read when the box was ticked or the View link was opened, which is
    /// exactly what a send carries. See `FeedbackSheet.captureLogs`.
    var logs = ""
    var images: [FeedbackImage] = []

    // MARK: - The prompt draft

    var prompt = ""
    /// Kept after a submission goes, unlike everything else: it is the same person next time, and
    /// typing your own name again to be credited again is a silly thing to ask of anybody.
    var name = ""

    private init() {}

    func open(_ sheet: Sheet) {
        self.sheet = sheet
    }

    func close() {
        sheet = nil
    }

    /// Called only after a report the server took.
    func clearReport() {
        message = ""
        includesLogs = false
        logs = ""
        images = []
    }

    /// Called only after a prompt the server took.
    func clearPrompt() {
        prompt = ""
    }
}
