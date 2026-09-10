import SwiftUI
import AppKit
import BloomCore

/// The destination and access implications stay visible while the user selects accounts.
struct ServerCredentialImportView: View {
    @State private var model: ServerCredentialImportModel
    let close: () -> Void
    @State private var copied = false

    init(model: ServerCredentialImportModel, close: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.close = close
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            Text(showsResults ? "Import results" : "Use accounts from this Mac").font(Typo.heading)
            Text(showsResults ? "Choose Done to return to server accounts." : "Choose which accounts to copy to your server. Your Mac stays signed in.")
                .font(Typo.label).foregroundStyle(.secondary)
            Label(model.connection.host, systemImage: "server.rack")
                .font(Typo.labelEmphasis).textSelection(.enabled)
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.gutter) {
                    if model.isDiscovering {
                        HStack { ProgressView().controlSize(.small); Text("Looking for accounts on this Mac…") }
                    } else if model.hasDiscovered && model.candidates.isEmpty {
                        Text("No accounts are available to import. Use Sign In in server accounts to connect a tool.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.candidates, id: \.self) { candidate in
                        account(candidate)
                        Divider()
                    }
                    ForEach(model.notices, id: \.self) { notice in
                        Text(notice).font(Typo.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Text("Claude uses its own sign-in flow. Choose Sign In next to Claude in server accounts.")
                        .font(Typo.caption).foregroundStyle(.secondary)
                    DisclosureGroup("Removing server access") {
                        Text("Signing out on the server removes its saved credentials. To invalidate a copied token, revoke it with the provider. Revoking a shared token can also sign out this Mac.")
                            .font(Typo.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            Text("Codex installs on the server if needed. Existing server sign-ins are preserved.")
                .font(Typo.caption).foregroundStyle(.secondary)
            Text("Only import to a server you trust. These credentials keep their existing permissions. Administrators and processes running as the Bloom user can access them. Transfer is encrypted over SSH.")
                .font(Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if model.isImporting {
                    ProgressView().controlSize(.small)
                    Text(model.isStopping ? "Stopping…" : "Importing \(model.currentAccount ?? "account")…")
                        .font(Typo.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if model.hasResults && !model.isImporting {
                    Button(copied ? "Copied" : "Copy Results") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.report, forType: .string)
                        copied = true
                    }
                }
                Spacer()
                if showsResults {
                    Button("Done", action: close)
                        .buttonStyle(.borderedProminent).tint(Palette.controlAccent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(model.isImporting ? "Stop" : model.hasResults ? "Done" : "Cancel") {
                        if model.isImporting { model.stop() } else { close() }
                    }
                    .keyboardShortcut(.cancelAction).disabled(model.isStopping)
                    Button("Import Selected Accounts") { model.startImport() }
                        .buttonStyle(.borderedProminent).tint(Palette.controlAccent)
                        .keyboardShortcut(.defaultAction).disabled(!model.canImport)
                }
            }
        }
        .padding(Metrics.gutter * 2)
        .frame(width: 660, height: 570)
        .interactiveDismissDisabled(model.isBusy)
        .onExitCommand { if !model.isBusy { close() } }
        .task { await model.discover() }
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copied = false
        }
        .onDisappear { model.cancel() }
    }

    private var showsResults: Bool { model.hasResults && !model.isBusy }

    private func account(_ candidate: ServerCredentialImport.Candidate) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            if showsResults || model.results[candidate]?.succeeded == true {
                Text(candidate.provider == .github ? "GitHub · \(candidate.displayName)" : candidate.displayName)
                    .font(Typo.labelEmphasis)
            } else {
                Toggle(isOn: Binding(get: { model.selected.contains(candidate) }, set: { model.select(candidate, enabled: $0) })) {
                VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                    Text(candidate.provider == .github ? "GitHub · \(candidate.displayName)" : candidate.displayName).font(Typo.labelEmphasis)
                    Text(candidate.detail).font(Typo.caption).foregroundStyle(.secondary)
                }
                }
                .disabled(model.isBusy)
            }
            if let result = model.results[candidate] {
                Label(result.message, systemImage: result.succeeded ? (result.verified ? "checkmark.circle.fill" : "info.circle") : "exclamationmark.triangle")
                    .font(Typo.caption).foregroundStyle(result.succeeded ? (result.verified ? Palette.controlAccent : Palette.textSecondary) : Palette.warning)
                    .textSelection(.enabled)
                if let recovery = result.recovery {
                    DisclosureGroup(result.succeeded ? "Removing this account" : "Recovery details") {
                        Text(recovery).font(Typo.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            } else if showsResults {
                Text("Not imported").font(Typo.caption).foregroundStyle(.secondary)
            }
        }
    }
}
