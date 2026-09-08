import SwiftUI
import BloomCore

/// Quick Look receives a downloaded copy, never a path on the other machine.
struct RemoteFilePreviewView: View {
    var server: ServerWindowModel
    var workspaceID: WorkspaceID
    var path: String
    @State private var localURL: URL?
    @State private var error: String?

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let localURL {
                    FileMediaView(worktree: "", path: path, sourceURL: localURL)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else if let error {
                    ContentUnavailableView("Cannot preview file", systemImage: "doc", description: Text(error))
                } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
        }
        .task(id: workspaceID.rawValue + path) {
            localURL = nil; error = nil
            do { localURL = try await server.download(path, workspaceID: workspaceID) } catch { self.error = error.localizedDescription }
        }
    }
}
