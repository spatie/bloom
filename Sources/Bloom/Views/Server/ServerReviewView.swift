import SwiftUI
import BloomCore

/// Supplies the server's listing to Bloom's existing inspector toolbar and file lists.
struct ServerReviewView: View {
    @Bindable var model: ServerReviewModel
    var server: ServerWindowModel?
    @State private var listing: RemoteWorkspaceFileListing?
    @State private var showsGitActions = false

    var body: some View {
        VStack(spacing: 0) {
            InspectorToolbar(selection: Binding(get: { model.showsAllFiles ? .allFiles : .changes },
                set: { model.showsAllFiles = $0 == .allFiles }),
                tabs: [.allFiles, .changes], fileCount: model.files.count) {
                Picker("Changes", selection: $model.scope) {
                    Text("Branch changes").tag(ServerDiffScope.branch)
                    Text("Uncommitted changes").tag(ServerDiffScope.uncommitted)
                }
            } worktreeMenu: {
                Button("Git Actions…") { showsGitActions = true }
            }
            .overlay(alignment: .bottom) { Hairline() }
            if let listing, listing.workspace.id == server?.selectedWorkspace?.id {
                if model.showsAllFiles { FileTreeView(model: listing) } else { ChangedFileList(model: listing) }
            } else {
                LoadingView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Palette.surface)
        .overlay(alignment: .top) { Hairline() }
        .task(id: server?.selectedWorkspace?.id) {
            if let server, let workspace = server.selectedWorkspace { listing = RemoteWorkspaceFileListing(workspace: workspace, server: server) }
        }
        .sheet(isPresented: $showsGitActions) {
            if let server {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Git Actions").font(Typo.title)
                    ServerGitActionsView(model: server)
                    Button("Done") { showsGitActions = false }.keyboardShortcut(.cancelAction)
                }.padding(24).frame(width: 430)
            }
        }
    }
}
