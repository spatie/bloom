import SwiftUI

/// The app's Mailpit inbox, opened from the sidebar footer. One server is configured for Bloom,
/// so its messages have one destination outside the workspace inspector.
struct MailView: View {
    @Environment(AppModel.self) private var app
    private var mailbox: Mailbox { .shared }

    var body: some View {
        GeometryReader { geometry in
            let listWidth = min(420, max(300, geometry.size.width * 0.36))

            Group {
                if showsEmptyInbox {
                    MailWelcomeView(port: mailbox.smtpPort)
                } else {
                    HStack(spacing: 0) {
                        MailListPane()
                            .frame(width: listWidth, height: geometry.size.height)
                        Hairline(axis: .vertical)
                            .frame(height: geometry.size.height)
                        MailPaneView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(Palette.surface)
        }
        .background(Palette.surface)
        .onChange(of: Mailbox.shared.link.presence.isEnabled) { _, enabled in
            if !enabled { app.selection = .home }
        }
    }

    /// One empty state for the whole destination, rather than an empty list beside an empty
    /// reader. Searching, loading and connection failures still use the list's own states.
    private var showsEmptyInbox: Bool {
        mailbox.connection == .live
            && mailbox.hasReadList
            && mailbox.list.total == 0
            && mailbox.query.isEmpty
    }
}
