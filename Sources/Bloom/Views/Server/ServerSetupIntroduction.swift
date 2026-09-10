import SwiftUI

/// Explain the outcome before asking for an address or administrator access.
struct ServerSetupIntroduction: View {
    let showAdvanced: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gutter) {
                benefit("Let agents keep working", symbol: "play.circle",
                        detail: "Close your laptop or quit Bloom. Your sessions keep running on the server.")
                benefit("Pick up on another device", symbol: "laptopcomputer",
                        detail: "Return to the same projects and conversations on your Mac, iPhone or iPad.")
                benefit("Preview beside your chat", symbol: "globe",
                        detail: "Open your running app inside Bloom through a private connection to your server.")

                VStack(alignment: .leading, spacing: Metrics.spacing) {
                    Text("What you’ll need").font(Typo.labelEmphasis)
                    Text("An Ubuntu server from your preferred hosting provider, with administrator access over SSH.")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Metrics.gutter)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.corner))

                VStack(alignment: .leading, spacing: Metrics.spacing) {
                    Text("What Bloom will install").font(Typo.labelEmphasis)
                    Text("Bloom Server, Git, GitHub CLI, tmux, Node.js and npm, with a dedicated server account and automatic startup. Browser testing tools are optional.")
                        .font(Typo.caption).foregroundStyle(Palette.textSecondary)
                    Text("You’ll review the installation plan and confirm before setup starts.")
                        .font(Typo.caption).foregroundStyle(Palette.textSecondary)
                }
                .fixedSize(horizontal: false, vertical: true)

                Button("Already running Bloom Server? Connect…", action: showAdvanced)
                    .buttonStyle(.link)
                    .font(Typo.caption)
            }
            .padding(.horizontal, 0)
            .padding(.vertical, Metrics.spacing)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func benefit(_ title: String, symbol: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: Metrics.gutter) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Palette.accent)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                Text(title).font(Typo.title)
                Text(detail)
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
