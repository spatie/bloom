import SwiftUI
import Observation
import BloomCore

/// The one box open on a diff, per file, for as long as the app is running.
///
/// It is a store rather than `@State` for the same two reasons the review draft is
/// (`WorkspaceModel.reviewDrafts`), and both of them destroy a view holding typed text. The band
/// lives in a lazy stack, so scrolling far enough from it tears it down. The diff view itself is
/// keyed by file path and re-keyed by the changed-file poll, so walking to another file, flipping
/// the whitespace toggle, or an agent's write moving a count tears the whole view down. Neither is
/// the user saying they are finished.
///
/// **Nothing here writes on its own.** The only write is `save`, it is always the user asking, and
/// it goes through `FileEditor.write`, which re-reads the file and refuses when it no longer holds
/// what the box was opened on. That refusal is the whole safety of the feature: the other writer
/// is a coding agent working in this very worktree, not a second human who would notice.
@MainActor
@Observable
final class DiffEditSession {
    /// Absolute paths are unique across workspaces, so one store serves all of them, the same as
    /// `FileEditSession`.
    static let shared = DiffEditSession()

    private init() {}

    /// Where a box is, what it was opened on, and what has happened to it since. Never the text:
    /// see `typed`.
    struct Editor: Sendable, Equatable {
        /// The whole file as it was when the box opened. What `FileEditor.write` compares against,
        /// and what `DiffEdit.apply` splices into.
        var baseline: EditableFile
        /// The lines the box stands for, in the file's own numbering.
        var region: DiffEditRegion
        var status: Status
    }

    enum Status: Sendable, Equatable {
        case editing
        /// The file moved under the box while it was open. Advisory only: the save's own check is
        /// what decides, and this is read from a poll that can be behind.
        case stale(String)
        /// A save was refused or failed. The text survives; only the disk was left alone.
        case failed(String)

        var warning: String? {
            switch self {
            case .editing: nil
            case let .stale(message), let .failed(message): message
            }
        }
    }

    /// Where each open box is. Read by the diff view's `body`, so it must not move on a keystroke.
    private(set) var editors: [String: Editor] = [:]

    /// What is being typed into each box, kept in its own stored property and never inside
    /// `Editor`.
    ///
    /// Observation is per stored property, so a character typed here invalidates only the views
    /// that read this dictionary, which is the one band it was typed into. Held together with the
    /// placement in one value, every keystroke would invalidate the diff's `body`, which rebuilds
    /// every row a lazy stack has realised. That is measured rather than feared: it is what
    /// `ReviewTextHost` was split out of `WorkspaceModel` to fix.
    private(set) var typed: [String: String] = [:]

    func editor(for path: String) -> Editor? { editors[path] }
    func text(for path: String) -> String { typed[path] ?? "" }
    func isOpen(_ path: String) -> Bool { editors[path] != nil }

    /// Whether the box holds something the file does not, which is what Save is offered on and
    /// what Cancel asks about.
    func isEdited(_ path: String) -> Bool {
        guard let editor = editors[path], let text = typed[path] else { return false }
        return editor.region.isEdited(text)
    }

    /// The buffer the editor binds to. Writing through it can only touch a box that is already
    /// open, so a keystroke arriving as one closes cannot invent one.
    func binding(for path: String) -> Binding<String> {
        Binding(
            get: { self.typed[path] ?? "" },
            set: { newValue in
                guard self.editors[path] != nil else { return }
                self.typed[path] = newValue
                // A refusal describes a save that has been overtaken by the next keystroke, so it
                // stops being true the moment one arrives. A staleness warning does not: the file
                // is still ahead of this box however much more is typed into it.
                if case .failed = self.editors[path]?.status { self.editors[path]?.status = .editing }
            }
        )
    }

    /// Open a box on the lines around `line`, or say why not.
    ///
    /// - Returns: nil when the box is open, or the sentence to put in front of the user. The
    ///   commonest of those sentences is the agent having rewritten the file since this diff was
    ///   drawn, which is a refusal rather than a failure: opening on the diff's numbers would put
    ///   the reader's typing into code they have never seen.
    func begin(path absolutePath: String, at line: Int, hunks: [DiffHunk]) async -> String? {
        // A box somebody has typed into is not moved out from under them by a click on another
        // line. An untouched one is only a view of the file and may be reopened anywhere.
        if isEdited(absolutePath), let region = editors[absolutePath]?.region {
            return "You are already editing \(Self.span(of: region)). Save or cancel that first."
        }

        let outcome = await Task.detached(priority: .userInitiated) {
            Self.locating(absolutePath, at: line, hunks: hunks)
        }.value

        switch outcome {
        case let .opened(editor):
            editors[absolutePath] = editor
            typed[absolutePath] = editor.region.text
            return nil
        case let .refused(message):
            return message
        }
    }

    /// Write the box back, or leave the disk alone and say why.
    ///
    /// - Returns: whether the file was written, which is what tells the caller to refresh the diff.
    func save(path absolutePath: String) async -> Bool {
        guard let editor = editors[absolutePath], let text = typed[absolutePath],
              editor.region.isEdited(text)
        else { return false }

        let outcome = await Task.detached(priority: .userInitiated) {
            Self.writing(text, of: editor.region, over: editor.baseline)
        }.value

        switch outcome {
        case .written:
            // Closed rather than reopened on the saved text. Every line number below the edit has
            // just moved, so the region describes a place that no longer exists, and the diff
            // being refreshed underneath is the point of having saved.
            close(path: absolutePath)
            return true
        case let .refused(message):
            editors[absolutePath]?.status = .failed(message)
            return false
        }
    }

    /// Take the box away. The user's Cancel, and the revert, which is about to replace the file.
    func close(path absolutePath: String) {
        editors[absolutePath] = nil
        typed[absolutePath] = nil
    }

    /// Compare the file against what the box was opened on, and carry the answer as the status.
    ///
    /// Called from the changed-file poll rather than by watching the file, because the poll is
    /// already reading this file for the review bands and a second watcher on a worktree an agent
    /// is churning would earn nothing. Being a poll, it can be behind, which is why nothing is
    /// disabled on the strength of it.
    func recheck(path absolutePath: String, contents: String?) {
        guard let editor = editors[absolutePath] else { return }
        // A refusal is what the user pressed Save and was told a moment ago. It says more than a
        // warning would, so it stands until the next keystroke.
        if case .failed = editor.status { return }

        let warning = DiffEdit.staleWarning(
            filename: editor.baseline.filename, baseline: editor.baseline.text, contents: contents
        )
        let next: Status = warning.map(Status.stale) ?? .editing
        guard next != editor.status else { return }
        editors[absolutePath]?.status = next
    }

    /// How a region is named to the reader. One line is a line; several are a range.
    static func span(of region: DiffEditRegion) -> String {
        region.lineCount == 1
            ? "line \(region.firstLine)"
            : "lines \(region.firstLine) to \(region.lastLine)"
    }

    /// Typed throws do not survive being caught inside a `Task.detached` closure, so both calls
    /// that cross that boundary are wrapped here, where the thrown type is still known. The same
    /// arrangement `FileEditSession` makes, and for the same reason.
    /// A refusal is a sentence rather than an error here, because every caller does the same
    /// thing with it: puts it in front of the reader. `Result` cannot carry one, since a `String`
    /// is not an `Error`, and inventing a wrapper to satisfy that would be a type nobody reads.
    private enum Located: Sendable {
        case opened(Editor)
        case refused(String)
    }

    private enum Written: Sendable {
        case written
        case refused(String)
    }

    nonisolated private static func locating(
        _ path: String, at line: Int, hunks: [DiffHunk]
    ) -> Located {
        do {
            let file = try FileEditor.read(path)
            let region = try DiffEdit.region(at: line, in: hunks, fileText: file.text)
            return .opened(Editor(baseline: file, region: region, status: .editing))
        } catch let error as FileEditorError {
            return .refused(message(for: error))
        } catch let error as DiffEditRefusal {
            return .refused(message(for: error))
        } catch {
            // Neither call throws anything else, and an error with no sentence attached to it is
            // the one thing a reader can do nothing with.
            return .refused(error.localizedDescription)
        }
    }

    nonisolated private static func writing(
        _ text: String, of region: DiffEditRegion, over baseline: EditableFile
    ) -> Written {
        do {
            let whole = try DiffEdit.apply(text, of: region, to: baseline.text)
            try FileEditor.write(whole, over: baseline)
            return .written
        } catch let error as DiffEditRefusal {
            return .refused(message(for: error))
        } catch let error as FileEditorError {
            return .refused(message(for: error))
        } catch {
            return .refused(error.localizedDescription)
        }
    }

    nonisolated private static func message(for error: some LocalizedError) -> String {
        error.errorDescription ?? "\(error)"
    }
}
