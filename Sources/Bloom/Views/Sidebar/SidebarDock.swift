import SwiftUI
import BloomCore

/// App-wide destinations in the sidebar footer. They stay available without taking a row from
/// the project list, which is where the reader spends most of their time.
struct SidebarDock: View {
    @Environment(AppModel.self) private var app

    @State private var isArchiveHovered = false
    @State private var isMailHovered = false

    var body: some View {
        HStack(spacing: Metrics.spacingSmall) {
            if Mailbox.shared.link.presence.isEnabled { mailButton }
            archiveButton
        }
    }

    private var mailButton: some View {
        Button { app.selection = .mail } label: {
            Label("Incoming mails", systemImage: "envelope")
                .labelStyle(.iconOnly)
                .font(Typo.label)
                .foregroundStyle(app.selection == .mail ? Palette.accent : Palette.textSecondary)
                .frame(width: Metrics.rowHeight, height: Metrics.rowHeight)
                .contentShape(Rectangle())
                .background(
                    isMailHovered ? Palette.hover : .clear,
                    in: RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                )
        }
        .buttonStyle(.plain)
        .onHoverChange { isMailHovered = $0 }
        .help(mailHelp)
        .accessibilityValue(Mailbox.shared.list.unread == 0 ? "No unread mail" : "\(Mailbox.shared.list.unread) unread")
    }

    private var archiveButton: some View {
        Button { showArchive() } label: {
            Label("Archive", systemImage: "archivebox")
                .labelStyle(.iconOnly)
                .font(Typo.label)
                .foregroundStyle(isShowingArchive ? Palette.accent : Palette.textSecondary)
                .frame(width: Metrics.rowHeight, height: Metrics.rowHeight)
                .contentShape(Rectangle())
                .background(
                    isArchiveHovered ? Palette.hover : .clear,
                    in: RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                )
        }
        .buttonStyle(.plain)
        .onHoverChange { isArchiveHovered = $0 }
        .help("Archived workspaces and conversations")
    }

    private var mailHelp: String {
        let unread = Mailbox.shared.list.unread
        return unread == 0 ? "Incoming mails" : "Incoming mails, \(unread) unread"
    }

    private var isShowingArchive: Bool {
        app.selection == .home && app.homeFilter.scope == .archived
    }

    private func showArchive() {
        app.homeFilter.scope = .archived
        app.homeFilter.projects = []
        app.selection = .home
    }
}
