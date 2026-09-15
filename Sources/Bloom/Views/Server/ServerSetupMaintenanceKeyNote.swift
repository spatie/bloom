import SwiftUI

/// Setup never mentioned the maintenance key, so the first time anybody learned of it was when a
/// second device asked for one. The Finish step is where it is still easy to act on.
struct ServerSetupMaintenanceKeyNote: View {
    /// Copies the key setup saved, returning false when this Mac holds none.
    let copyKey: () throws -> Bool
    @State private var confirmsCopy = false
    @State private var feedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
            Label("Updates are protected by a maintenance key", systemImage: "key")
            Text("The key is kept in this Mac’s Keychain, and the server stores only a hash of it. To install updates from another device, add the key there in Server Settings > Updates.")
                .font(Typo.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Copy Key for Another Device…") { confirmsCopy = true }.linkButton()
            if let feedback { Text(feedback).font(Typo.caption).foregroundStyle(.secondary) }
        }
        .confirmationDialog("Copy maintenance access?", isPresented: $confirmsCopy, titleVisibility: .visible) {
            Button("Copy Key") {
                do {
                    feedback = try copyKey()
                        ? "Key copied. Paste it into Maintenance Access on your other device."
                        : "This Mac has no maintenance key for the server."
                } catch { feedback = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This key allows server updates. Share it only with a device you trust. It will be removed from this Mac’s clipboard after one minute.") }
    }
}
