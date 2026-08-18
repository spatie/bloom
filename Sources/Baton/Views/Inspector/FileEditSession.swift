import SwiftUI
import Observation
import BatonCore

/// The buffers behind Edit mode, one per file, for as long as the inspector is showing this
/// workspace.
///
/// Drafts are kept per path rather than thrown away when the pane changes, because the pane
/// changes for reasons that have nothing to do with the user being finished: clicking the next
/// file, flipping back to the diff to check something, the file list refreshing underneath. None
/// of those should silently discard typed text. Nothing here writes to disk on its own; the only
/// write is `save`, and it is always the user asking.
@MainActor
@Observable
final class FileEditSession {
    /// One file's editing state. `baseline` is the exact bytes the text was loaded from, which is
    /// what makes a save checkable rather than hopeful.
    struct Draft {
        var baseline: EditableFile
        var text: String

        var isDirty: Bool { text != baseline.text }
    }

    enum Status: Equatable {
        case idle
        case loading
        /// The file cannot be edited at all: missing, binary, or too large.
        case unavailable(String)
        /// A save was refused or failed. The draft survives; only the disk was left alone.
        case failed(String)
        case saved
    }

    private(set) var drafts: [String: Draft] = [:]
    private(set) var status: [String: Status] = [:]

    func status(for path: String) -> Status { status[path] ?? .idle }
    func draft(for path: String) -> Draft? { drafts[path] }
    func isDirty(_ path: String) -> Bool { drafts[path]?.isDirty ?? false }

    /// The buffer the editor binds to. Writing through it can only ever touch a draft that has
    /// already been loaded, so a keystroke arriving during a reload cannot invent one.
    func binding(for path: String) -> Binding<String> {
        Binding(
            get: { self.drafts[path]?.text ?? "" },
            set: { newValue in
                guard var draft = self.drafts[path] else { return }
                draft.text = newValue
                self.drafts[path] = draft
                if case .saved = self.status(for: path) { self.status[path] = .idle }
            }
        )
    }

    /// Read the file, unless there is already a draft for it.
    ///
    /// An existing draft wins on purpose: reloading over one would be the data loss this whole
    /// type exists to avoid. Re-reading the file to see whether it moved on underneath is the
    /// save's job, where there is a user to tell about it.
    func load(path absolutePath: String) async {
        guard drafts[absolutePath] == nil else { return }
        status[absolutePath] = .loading

        let outcome = await Task.detached(priority: .userInitiated) {
            Self.reading(absolutePath)
        }.value

        switch outcome {
        case let .success(file):
            drafts[absolutePath] = Draft(baseline: file, text: file.text)
            status[absolutePath] = .idle
        case let .failure(error):
            status[absolutePath] = .unavailable(Self.message(for: error))
        }
    }

    /// Write the draft back, or explain why it was not written.
    ///
    /// The guard lives in `FileEditor.write`, which re-reads the file and refuses when its
    /// contents no longer match what this draft was loaded from. That is the case the agent
    /// causes: it edited the same file while the user was typing, and overwriting it would throw
    /// away work nobody has seen.
    func save(path absolutePath: String) async {
        guard let draft = drafts[absolutePath], draft.isDirty else { return }

        let text = draft.text
        let baseline = draft.baseline
        let outcome = await Task.detached(priority: .userInitiated) {
            Self.writing(text, over: baseline)
        }.value

        switch outcome {
        case let .success(saved):
            drafts[absolutePath] = Draft(baseline: saved, text: saved.text)
            status[absolutePath] = .saved
        case let .failure(error):
            status[absolutePath] = .failed(Self.message(for: error))
        }
    }

    /// Throw the draft away and read the file again. Only ever called from an explicit button,
    /// and only after the user has been told what it costs.
    func reload(path absolutePath: String) async {
        drafts[absolutePath] = nil
        status[absolutePath] = .idle
        await load(path: absolutePath)
    }

    /// Forget a file entirely, for when the file itself is about to stop existing.
    func discard(path absolutePath: String) {
        drafts[absolutePath] = nil
        status[absolutePath] = nil
    }

    /// Typed throws do not survive being caught inside a `Task.detached` closure, so the two
    /// calls that cross that boundary are wrapped here where the thrown type is still known.
    nonisolated private static func reading(_ path: String) -> Result<EditableFile, FileEditorError> {
        do { return .success(try FileEditor.read(path)) } catch { return .failure(error) }
    }

    nonisolated private static func writing(
        _ text: String, over baseline: EditableFile
    ) -> Result<EditableFile, FileEditorError> {
        do { return .success(try FileEditor.write(text, over: baseline)) }
        catch { return .failure(error) }
    }

    private static func message(for error: FileEditorError) -> String {
        error.errorDescription ?? "\(error)"
    }
}
