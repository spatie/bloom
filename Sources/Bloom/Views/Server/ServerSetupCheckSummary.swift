import SwiftUI
import BloomCore

/// Keep the result and its supporting details together, aligned beneath a single status icon.
struct ServerSetupCheckSummary: View {
    let check: ServerInstallCheck
    let showAdvanced: () -> Void
    var stopServer: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.spacingWide) {
            Image(systemName: check.blockers.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle")
                .foregroundStyle(check.blockers.isEmpty ? Palette.controlAccent : Palette.warning)
                .frame(width: 20).padding(.top, 2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Metrics.spacing) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Metrics.spacingWide) { status; system }.fixedSize()
                    VStack(alignment: .leading, spacing: Metrics.spacingSmall) { status; system }
                }
                ForEach(check.blockers, id: \.code) { notice in
                    ServerSetupNoticeView(notice: notice, serviceUser: check.serviceUser, showAdvanced: showAdvanced,
                        stopServer: notice.code == "server_running" ? stopServer : nil)
                }
                ForEach(check.warnings, id: \.code) { notice in
                    HStack(spacing: Metrics.spacingSmall) {
                        Text(notice.code == "limited_memory" ? "Less than 2 GB of memory" : notice.message)
                            .font(Typo.caption).foregroundStyle(.secondary)
                        ServerSetupHelpButton(title: notice.code == "limited_memory" ? "Memory requirements" : "Server warning", details: notice.message)
                    }
                }
                if check.existing { Text("Existing projects will be preserved.").font(Typo.caption).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Metrics.gutter)
        .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.corner))
    }

    private var status: some View {
        Text(check.blockers.isEmpty ? "Ready for setup" : "Setup needs attention")
            .font(Typo.labelEmphasis)
            .foregroundStyle(check.blockers.isEmpty ? Palette.controlAccent : Palette.warning)
    }

    private var system: some View {
        Text("\(check.platform) · \(check.architecture)").font(Typo.caption).foregroundStyle(.secondary)
    }
}
