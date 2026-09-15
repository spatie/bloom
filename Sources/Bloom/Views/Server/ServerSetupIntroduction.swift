import SwiftUI
import BloomCore
import BloomUI

/// Introduce remote work visually, and say what the server must be before anyone types an
/// address. The supported systems used to appear only as a failed check.
struct ServerSetupIntroduction: View {
    let showAdvanced: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gutter) {
                BloomServerIllustration(accent: Palette.controlAccent)
                    .background(Palette.surfaceSunken)
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.corner * 2))
                HStack(alignment: .top, spacing: Metrics.gutter * 1.5) {
                    benefit("Keep agents working", symbol: "play.circle",
                            detail: "Agents keep running while your Mac sleeps or is offline.")
                    benefit("Pick up anywhere", symbol: "laptopcomputer.and.iphone",
                            detail: "Your projects on Mac, iPhone and iPad.")
                    benefit("Preview your work", symbol: "globe",
                            detail: "Open your app beside the chat.")
                }
                Divider()
                VStack(alignment: .leading, spacing: Metrics.spacing) {
                    Text(ServerInstallationSummary.requirementsTitle).font(Typo.labelEmphasis)
                    requirement(ServerInstallationSummary.supportedSystem, symbol: "server.rack")
                    requirement(ServerInstallationSummary.administratorAccess, symbol: "key")
                    requirement(ServerInstallationSummary.separateAccount, symbol: "person.crop.circle")
                }
                .fixedSize(horizontal: false, vertical: true)
                Button("Already running Bloom Server? Connect…", action: showAdvanced)
                    .linkButton().font(Typo.caption)
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

    private func requirement(_ text: String, symbol: String) -> some View {
        Label {
            Text(text).font(Typo.caption).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Palette.textSecondary)
        }
    }
}
