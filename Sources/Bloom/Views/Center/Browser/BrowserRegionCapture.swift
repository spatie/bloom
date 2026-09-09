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
    var selection: CGRect?
    var comment = ""
    var isAdding = false
    var failure: String?

    var imageSize: CGSize { CGSize(width: image.width, height: image.height) }
    var canAdd: Bool {
        selection != nil && !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isAdding
    }

    init(data: Data, address: String, session: Session) throws {
        guard let bitmap = NSBitmapImageRep(data: data), let image = bitmap.cgImage else {
            throw BrowserSnapshotFailure()
        }
        self.image = image
        self.address = address
        sessionID = session.id
        conversation = session.title
    }

    func add(to model: WorkspaceModel, completion: @escaping @MainActor () -> Void) {
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
                sessionID: sessionID, revealConversation: false
            ) { paths in
                BrowserRegion.draft(comment: comment, address: address, paths: paths)
            }
            if let failure = outcome.failure {
                self.failure = failure
            } else {
                completion()
            }
        }
    }
}
