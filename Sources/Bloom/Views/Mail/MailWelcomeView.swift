import SwiftUI

/// The connected inbox before its first message. There is no reader or search result to show yet.
struct MailWelcomeView: View {
    let port: Int

    var body: some View {
        VStack(spacing: Metrics.gutter) {
            Image(systemName: "envelope.open")
                .font(.system(size: 36, weight: .ultraLight))
                .foregroundStyle(Palette.textTertiary)
                .accessibilityHidden(true)

            VStack(spacing: Metrics.spacingSmall) {
                Text("Your inbox is empty")
                    .font(Typo.heading)
                    .foregroundStyle(Palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("Send a test email from your app. It will appear here.")
                    .font(Typo.body)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }

            MailSetupButton(port: port)
        }
        .frame(maxWidth: 400)
        .padding(Metrics.pane)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

/// The same guide from the empty inbox and Settings, with the port of this app bundle.
struct MailSetupButton: View {
    let port: Int
    @State private var showingGuide = false

    var body: some View {
        Button("How to send a test email") { showingGuide = true }
            .buttonStyle(.bordered)
            .popover(isPresented: $showingGuide, arrowEdge: .bottom) {
                MailSetupGuide(port: port)
                    .frame(width: 340)
                    .padding(Metrics.pane)
            }
    }
}

private struct MailSetupGuide: View {
    let port: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            Text("Send a test email")
                .font(Typo.title)

            Text("Set your app's SMTP connection to:")
                .font(Typo.body)
            VStack(alignment: .leading, spacing: Metrics.spacing) {
                setting("Host", "127.0.0.1")
                setting("Port", String(port))
                setting("Encryption", "None")
                setting("Authentication", "None")
            }
            Text("Keep Bloom open, then send an email from your app. Bloom will capture it here.")
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
        }
    }

    private func setting(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name)
                .foregroundStyle(Palette.textSecondary)
            Spacer(minLength: Metrics.gutter)
            Text(value)
                .font(Typo.codeSmall)
                .textSelection(.enabled)
        }
        .font(Typo.label)
    }
}
