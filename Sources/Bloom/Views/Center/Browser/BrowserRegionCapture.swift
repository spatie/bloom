import AppKit
import Observation
import BloomCore

/// Holds the captured page and conversation while the reader writes. Neither a navigation nor a
/// switch to another chat should change what the comment refers to or where it is attached.
@MainActor @Observable
final class BrowserRegionCapture {
    let image: CGImage
    let address: String
    let sessionID: SessionID
    let conversation: String
    /// The web content's position within the viewport, excluding an attached web inspector.
    let pageRect: CGRect
    let viewportSize: CGSize?
    var selection: CGRect?
    var comment = ""
    var isEditing = false
    var isAdding = false
    var failure: String?
    var comments: [BrowserRegionComment] = []
    var focusedCommentPath: String?
    var editingCommentPath: String?
    private var editDrafts: [String: String] = [:]

    var focusedComment: BrowserRegionComment? { comments.first { $0.id == focusedCommentPath } }

    func beginSelection() {
        if let editingCommentPath {
            editDrafts[editingCommentPath] = comment
            comment = ""
        }
        editingCommentPath = nil
        focusedCommentPath = nil
        isEditing = false
    }

    func beginEdit(_ note: BrowserRegionComment) {
        selection = nil
        focusedCommentPath = note.id
        editingCommentPath = note.id
        comment = editDrafts[note.id] ?? note.body
        isEditing = true
    }

    func cancelEdit() {
        if let editingCommentPath { editDrafts[editingCommentPath] = nil }
        editingCommentPath = nil
        comment = ""
        isEditing = false
    }

    func synchronise(with draft: String) {
        let paths = Set(AttachmentDraft.parse(draft).paths)
        comments.removeAll { !paths.contains($0.path) }
        if let focusedCommentPath, !comments.contains(where: { $0.id == focusedCommentPath }) {
            self.focusedCommentPath = nil
            editingCommentPath = nil
            isEditing = false
        }
    }

    func saveEdit(in model: some WorkspacePaneModel) {
        guard let note = focusedComment, editingCommentPath == note.id,
              !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let transcript = model.existingTranscript(for: sessionID),
              AttachmentDraft.parse(transcript.draft).paths.contains(note.path),
              let index = comments.firstIndex(where: { $0.id == note.id }) else { return }
        comments[index].body = comment
        PromptAttachmentStore.shared.annotate(
            paths: [note.path], with: BrowserImageComment(body: comment, address: address), sessionID: sessionID.rawValue
        )
        cancelEdit()
    }

    func remove(_ note: BrowserRegionComment, from model: some WorkspacePaneModel) {
        guard let transcript = model.existingTranscript(for: sessionID) else { return }
        let draft = AttachmentDraft.parse(transcript.draft).keeping { $0 != note.path }
        transcript.draft = draft
        transcript.remote?.saveDraft(draft)
        comments.removeAll { $0.id == note.id }
        editDrafts[note.id] = nil
        if focusedCommentPath == note.id {
            focusedCommentPath = nil
            cancelEdit()
        }
        if !AttachmentDraft.parse(draft).paths.contains(note.path),
           let attachment = PromptAttachmentStore.shared.attachments(for: sessionID.rawValue).first(where: { $0.path == note.path }) {
            PromptAttachmentStore.shared.remove(attachment, sessionID: sessionID.rawValue, workspace: model.workspace.path)
        }
    }

    var imageSize: CGSize { CGSize(width: image.width, height: image.height) }
    var canAdd: Bool {
        selection != nil && !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isAdding
    }

    init(
        data: Data, address: String, session: Session,
        pageRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
        viewportSize: CGSize? = nil
    ) throws {
        guard let bitmap = NSBitmapImageRep(data: data), let image = bitmap.cgImage else {
            throw BrowserSnapshotFailure()
        }
        self.image = image
        self.address = address
        sessionID = session.id
        conversation = session.title
        self.pageRect = pageRect
        self.viewportSize = viewportSize
    }

    static func pageRect(in browser: BrowserSession) -> CGRect {
        BrowserRegion.pageFrame(
            content: browser.webView.convert(browser.webView.bounds, to: browser.pageView),
            viewport: browser.pageView.bounds,
            originAtTop: browser.pageView.isFlipped
        )
    }

    func add(to model: some WorkspacePaneModel, completion: @escaping @MainActor () -> Void) {
        guard canAdd, let selection,
              let rect = BrowserRegion.pixels(selection, image: imageSize),
              let crop = image.cropping(to: rect),
              let data = NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:]) else {
            failure = "Select an area and write a comment before adding it."
            return
        }
        isAdding = true
        failure = nil
        let comment = self.comment
        let address = self.address
        // Once Add is pressed the handoff belongs to the draft, even if this pane closes while
        // the attachment is being written. It must finish without revealing a different tab.
        Task {
            defer { isAdding = false }
            let taken = Set(PromptAttachmentStore.shared.attachments(for: sessionID.rawValue).map(\.filename))
            let name = BrowserSnapshot.filename(for: address, avoiding: taken)
            let outcome = await ComposerHandoff.attach(
                [.image(data, format: .png, named: name)], to: model,
                sessionID: sessionID, revealConversation: false,
                imageComment: BrowserImageComment(body: comment, address: address)
            )
            if let failure = outcome.failure {
                self.failure = failure
            } else {
                if let path = outcome.paths.first {
                    let note = BrowserRegionComment(path: path, selection: selection, address: address, body: comment)
                    comments.append(note)
                    focusedCommentPath = note.id
                }
                self.selection = nil
                self.comment = ""
                isEditing = false
                completion()
            }
        }
    }
}
