import Foundation
import Observation
import BloomCore

/// Each file owns its edit buffer, so switching workspaces cannot redirect a delayed text-view
/// edit into another file. The revision belongs to the loaded contents, never to a later poll.
@MainActor
@Observable
final class ServerFileBuffer {
    let workspaceID: WorkspaceID
    let path: String
    let endpoint: ServerEndpoint
    var text: String
    private(set) var savedText: String
    private(set) var revision: String
    var isSaving = false
    var error: String?

    init(file: ServerTextFile, workspaceID: WorkspaceID, endpoint: ServerEndpoint) {
        self.workspaceID = workspaceID
        self.path = file.path
        self.endpoint = endpoint
        text = file.text
        savedText = file.text
        revision = file.revision
    }

    var hasChanges: Bool { text != savedText }

    func receive(_ file: ServerTextFile) {
        guard !hasChanges else { return }
        text = file.text
        savedText = file.text
        revision = file.revision
    }

    func saved(_ file: ServerTextFile, submitted: String) {
        if text == submitted { text = file.text }
        savedText = file.text
        revision = file.revision
        error = nil
    }
}
