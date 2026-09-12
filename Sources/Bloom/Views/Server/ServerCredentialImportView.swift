import SwiftUI
import AppKit
import BloomCore

/// Consent belongs to account selection; completed imports show outcomes and the next action.
struct ServerCredentialImportView: View {
    @State private var model: ServerCredentialImportModel
    let close: () -> Void
    @State private var copied = false
    @State private var showsAccessHelp = false

    init(model: ServerCredentialImportModel, close: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.close = close
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            VStack(alignment: .leading, spacing: Metrics.spacing) {
                Text(showsResults ? "Import results" : "Use accounts from this Mac").font(Typo.heading)
                if !showsResults {
                    Text("Choose accounts to copy. Your Mac stays signed in.")
                        .font(Typo.label).foregroundStyle(.secondary)
                }
                Label(model.connection.host, systemImage: "server.rack")
                    .font(Typo.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.gutter) {
                    if model.isDiscovering {
                        HStack { ProgressView().controlSize(.small); Text("Looking for accounts on this Mac…") }
                    } else if model.hasDiscovered && model.candidates.isEmpty {
                        Text("No accounts are available to import. Use Sign In in server accounts to connect a tool.")
                            .foregroundStyle(.secondary)
                    }
                    VStack(spacing: 0) {
                        ForEach(model.candidates, id: \.self) { candidate in
                            if candidate != model.candidates.first { Divider() }
                            account(candidate).padding(.vertical, Metrics.gutter)
                        }
                    }
                    if !showsResults {
                        ForEach(model.notices, id: \.self) { notice in
                            Text(notice).font(Typo.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    Text("Claude requires a separate sign-in in server accounts.")
                        .font(Typo.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            if !showsResults {
                VStack(alignment: .leading, spacing: Metrics.spacing) {
                    Text("Codex installs on the server if needed. Existing server sign-ins are preserved.")
                    Text(accessExplanation)
                }
                .font(Typo.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                showsAccessHelp = true
            } label: {
                Label("Account access and sign-out", systemImage: "questionmark.circle")
                    .font(Typo.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showsAccessHelp, arrowEdge: .bottom) { accessHelp }
            footer
        }
        .padding(Metrics.gutter * 2)
        .frame(width: 580, height: showsResults ? 370 : 540)
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

    private var accessExplanation: String {
        "Only copy accounts to a server you trust. Credentials keep their permissions and are accessible to server administrators and processes running as the Bloom user. Transfer is encrypted over SSH."
    }

    private var footer: some View {
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
                Button("Copy Selected Accounts") { model.startImport() }
                    .buttonStyle(.borderedProminent).tint(Palette.controlAccent)
                    .keyboardShortcut(.defaultAction).disabled(!model.canImport)
            }
        }
    }

    private func account(_ candidate: ServerCredentialImport.Candidate) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            if showsResults || model.results[candidate]?.succeeded == true {
                HStack(alignment: .firstTextBaseline) {
                    accountIdentity(candidate)
                    Spacer(minLength: Metrics.gutter)
                    if let result = model.results[candidate] {
                        if result.succeeded {
                            Label(result.verified ? "Verified on server" : "Copied, not yet verified",
                                  systemImage: result.verified ? "checkmark.circle.fill" : "info.circle")
                                .font(Typo.caption)
                                .foregroundStyle(result.verified ? Palette.controlAccent : Palette.textSecondary)
                                .help(result.message)
                        } else {
                            Label("Needs attention", systemImage: "exclamationmark.triangle")
                                .font(Typo.caption).foregroundStyle(Palette.warning)
                        }
                    } else {
                        Text("Not copied").font(Typo.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Toggle(isOn: Binding(get: { model.selected.contains(candidate) }, set: { model.select(candidate, enabled: $0) })) {
                    VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                        accountIdentity(candidate)
                        Text(candidate.detail).font(Typo.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(model.isBusy)
            }
            if let result = model.results[candidate], !result.succeeded {
                Text(result.message).font(Typo.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if let recovery = result.recovery {
                    Text(recovery).font(Typo.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func accountIdentity(_ candidate: ServerCredentialImport.Candidate) -> some View {
        Text(candidate.provider == .github ? "GitHub · \(candidate.displayName)" : candidate.displayName)
            .font(Typo.labelEmphasis).textSelection(.enabled)
    }

    private var accessHelp: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gutter) {
                Text("Account access").font(Typo.labelEmphasis)
                Text(accessExplanation)
                Text("Signing out on the server removes its saved credentials. To invalidate a copied token, revoke it with the provider. Revoking a shared token can also sign out this Mac.")
                ForEach(model.candidates, id: \.self) { candidate in
                    if let result = model.results[candidate], result.succeeded {
                        VStack(alignment: .leading, spacing: Metrics.spacing) {
                            accountIdentity(candidate)
                            Text(result.message)
                            if let recovery = result.recovery { Text(recovery) }
                        }
                    }
                }
            }
            .font(Typo.caption).foregroundStyle(.secondary).textSelection(.enabled)
            .padding(Metrics.gutter)
        }
        .frame(width: 380, height: showsResults ? 330 : 200)
    }
}
