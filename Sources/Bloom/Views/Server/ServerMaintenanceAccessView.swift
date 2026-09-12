import SwiftUI
import AppKit
import BloomAuthentication

struct ServerMaintenanceAccessView: View {
    @Bindable var access: ServerMaintenanceAccess
    let serverName: String
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var feedback: String?
    @State private var confirmsCopy = false
    @State private var confirmsRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Maintenance Access").font(Typo.heading)
            Text("Allow this Mac to manage updates on \(serverName). The key is separate from SSH keys and agent sign-ins.")
                .foregroundStyle(.secondary)
            SecureField("Maintenance key", text: $key)
                .textFieldStyle(.roundedBorder)
                .accessibilityHint("Use the maintenance key created during server setup.")
            Text("Saved in this Mac’s Keychain. It does not sync to iCloud or appear in reports.").font(Typo.caption).foregroundStyle(.secondary)
            if let error = access.credentialFailure ?? access.session.failure?.message {
                Text(error).font(Typo.caption).foregroundStyle(Palette.warning).textSelection(.enabled)
            }
            if let feedback { Text(feedback).font(Typo.caption).foregroundStyle(.secondary) }
            if access.hasSavedCredential {
                HStack {
                    Button("Copy Key for Another Device…") { confirmsCopy = true }
                    Spacer()
                    Button("Remove from This Mac…", role: .destructive) { confirmsRemoval = true }
                }.disabled(access.isPairing || access.session.activity != .idle || access.session.pendingMutationID != nil)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(access.isPairing)
                Spacer()
                if access.isPairing { ProgressView().controlSize(.small) }
                Button(access.hasSavedCredential ? "Replace Key" : "Add Access") {
                    Task {
                        if await access.pair(token: key) { key = ""; dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || access.isPairing || access.session.activity != .idle)
            }
        }
        .padding(24)
        .frame(width: 480)
        .interactiveDismissDisabled(access.isPairing)
        .onDisappear { key = "" }
        .confirmationDialog("Copy maintenance access?", isPresented: $confirmsCopy, titleVisibility: .visible) {
            Button("Copy Key") { copyKey() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This key allows server updates. Share it only with a device you trust. It will be removed from this Mac’s clipboard after one minute.") }
        .confirmationDialog("Remove maintenance access from this Mac?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button("Remove Access", role: .destructive) {
                do { try access.forget(); key = ""; dismiss() } catch { feedback = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Updates already running on the server will continue. Other devices keep their access.") }
    }

    private func copyKey() {
        do {
            guard let token = try ServerMaintenanceCredentials.load(serverID: access.serverID) else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(token, forType: .string)
            pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            let change = pasteboard.changeCount
            feedback = "Key copied. Paste it into Maintenance Access on your other device."
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(60))
                if pasteboard.changeCount == change { pasteboard.clearContents() }
            }
        } catch { feedback = error.localizedDescription }
    }
}
