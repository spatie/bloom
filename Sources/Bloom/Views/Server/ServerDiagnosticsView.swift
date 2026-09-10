import SwiftUI
import BloomCore

/// Checks stay in server settings. Creating a workspace does not require a checklist.
struct ServerDiagnosticsView: View {
    let model: ServerWindowModel
    @Environment(\.openWindow) private var openWindow
    @State private var report: ServerDiagnostics?
    @State private var error: String?
    @State private var isLoading = false
    @State private var requestID = UUID()

    var body: some View {
        Section("Server checks") {
            HStack {
                Text(report?.summary ?? "Check tools and available resources")
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
                Button(report == nil ? "Check Server" : "Refresh") { Task { await refresh() } }
                    .disabled(isLoading)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if let report {
                DisclosureGroup("Details") {
                    Text("\(report.hostname), account \(report.account)").font(.caption).foregroundStyle(.secondary)
                    ForEach(report.checks) { check in
                        VStack(alignment: .leading, spacing: 3) {
                            Label(check.title, systemImage: symbol(check.status))
                                .foregroundStyle(check.status == .attention ? Color.orange : Color.secondary)
                            Text(check.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            if check.id == .github && check.status != .ready {
                                Button("Sign In on Server…") { openWindow(id: ServerAccountsWindow.id) }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 3)
                    }
                    Text("Checked \(report.checkedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: model.endpoint) { _, _ in
            requestID = UUID(); report = nil; error = nil; isLoading = false
        }
    }

    private func symbol(_ status: ServerDiagnostics.Check.Status) -> String {
        switch status {
        case .ready: "checkmark.circle"
        case .attention: "exclamationmark.triangle"
        case .unavailable: "minus.circle"
        }
    }

    @MainActor private func refresh() async {
        let id = UUID()
        requestID = id
        isLoading = true; error = nil
        defer { if requestID == id { isLoading = false } }
        do {
            let result = try await model.read(.diagnostics)
            guard requestID == id else { return }
            guard case .diagnostics(let value) = result else { throw ServerFailure("The server did not return its checks. Update the server and try again.") }
            report = value
        } catch {
            guard requestID == id else { return }
            self.error = error.localizedDescription
        }
    }
}
