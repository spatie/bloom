import SwiftUI
import AppKit
import BloomCore

struct ServerToolUpdatesView: View {
    @Bindable var model: ServerToolUpdatesModel
    let showConnection: () -> Void
    let showAccounts: () -> Void
    @State private var review: ServerToolUpdatesModel.Review?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if model.connection == nil {
                    Section("Update server tools") {
                        Text("Connect with the server’s verified SSH connection to manage its AI tools.")
                            .settingsFootnote()
                        Button("Connection Settings", action: showConnection)
                    }
                } else {
                    Section {
                        ForEach(model.installations) { installation in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(installation.tool.title).font(Typo.labelEmphasis)
                                    if let version = installation.version {
                                        Text(version).foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                    Text(installation.detail).settingsFootnote()
                                    if let path = installation.path {
                                        Text(path).font(Typo.codeSmall).foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                }
                                Spacer()
                                if installation.canUpdate {
                                    Button("Update…") { review = model.review(installation.tool) }
                                        .disabled(!model.canUpdate)
                                        .accessibilityLabel("Update " + installation.tool.title)
                                } else if installation.path == nil {
                                    Button("Set Up…", action: showAccounts)
                                        .disabled(model.updating != nil)
                                }
                            }
                        }
                        if model.isLoading { ProgressView("Checking installed versions…").controlSize(.small) }
                    } header: {
                        Text("AI tools")
                    } footer: {
                        Text("Updates use the server account and keep its sign-ins. System packages and tools inside project containers are managed separately.")
                            .settingsFootnote()
                    }
                    if let updating = model.updating {
                        Section { ProgressView("Updating \(updating.title)…").controlSize(.small) }
                    }
                    if let failure = model.failure {
                        Section("Update needs attention") {
                            Text(failure).foregroundStyle(Palette.warning).textSelection(.enabled)
                            Text("Refresh before trying again. The tool may already have changed.").settingsFootnote()
                        }
                    } else if let result = model.result {
                        Section { Label(result, systemImage: "checkmark.circle").textSelection(.enabled) }
                    }
                }
            }
            .settingsForm()
            if !model.activity.lines.isEmpty {
                VStack(alignment: .leading, spacing: Metrics.spacing) {
                    Text("Server output").font(Typo.captionEmphasis)
                    ServerSetupOutputView(lines: model.activity.lines)
                        .frame(minHeight: 130, idealHeight: 180, maxHeight: 220)
                }.padding(Metrics.gutter)
            }
            HStack {
                Button("Copy Report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.diagnosticReport, forType: .string)
                }
                Spacer()
                Button("Refresh") { Task { await model.refresh() } }
                    .disabled(model.connection == nil || model.isLoading || model.updating != nil)
            }.padding(Metrics.gutter)
        }
        .task(id: model.server.connectionGeneration) { await model.refresh() }
        .confirmationDialog("Update \(review?.tool.title ?? "tool") on \(review?.serverName ?? "server")?",
                            isPresented: Binding(get: { review != nil }, set: { if !$0 { review = nil } }),
                            titleVisibility: .visible, presenting: review) { selected in
            Button("Update " + selected.tool.title) { Task { await model.update(selected) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Download and install the vendor’s current release for this installation. Finish agent turns before updating and avoid starting new ones until it completes. Existing sign-ins are kept.")
        }
    }
}
