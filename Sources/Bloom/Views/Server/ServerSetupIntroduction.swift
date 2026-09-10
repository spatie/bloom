import SwiftUI
import BloomUI

/// Introduce remote work visually, with the requirements and installation decision still in view.
struct ServerSetupIntroduction: View {
    let showAdvanced: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gutter) {
                BloomServerIllustration(accent: Palette.controlAccent)
                    .environment(\.colorScheme, .dark)
                    .background { BrandWater() }
                    .background(Brand.depth)
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.corner * 2))
                HStack(alignment: .top, spacing: Metrics.gutter * 1.5) {
                    benefit("Keep agents working", symbol: "play.circle",
                            detail: "Close your laptop. Your sessions keep running on the server.")
                    benefit("Pick up anywhere", symbol: "laptopcomputer.and.iphone",
                            detail: "The same projects and chats on your Mac, iPhone or iPad.")
                    benefit("Preview your work", symbol: "globe",
                            detail: "Open your app beside the chat through a private connection.")
                }
                Divider()
                VStack(alignment: .leading, spacing: Metrics.spacing) {
                    Text("Bring an Ubuntu server").font(Typo.labelEmphasis)
                    Text("Use your preferred hosting provider. You’ll need administrator access over SSH.")
                        .font(Typo.caption).foregroundStyle(Palette.textSecondary)
                    Text("Bloom installs its server, Git, GitHub CLI, tmux, Node.js and npm, with automatic startup. Browser testing tools are optional. You’ll review and confirm the installation first.")
                        .font(Typo.caption).foregroundStyle(Palette.textSecondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                Button("Already running Bloom Server? Connect…", action: showAdvanced)
                    .buttonStyle(.link).font(Typo.caption)
            }
            .padding(.vertical, Metrics.spacing)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func benefit(_ title: String, symbol: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
            Label(title, systemImage: symbol).font(Typo.captionEmphasis).foregroundStyle(Palette.controlAccent)
            Text(detail).font(Typo.caption).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
