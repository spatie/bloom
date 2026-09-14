import SwiftUI
import BloomCore

struct AskTabStrip: View {
    @Environment(AppModel.self) private var app
    @State private var renaming: SessionID?
    @State private var isNewTabHovered = false
    @Namespace private var selection

    var body: some View {
        TabStrip(selection: app.ask.selectedID) {
            EmptyView()
        } tabs: {
            HStack(spacing: 0) {
                ForEach(app.ask.sessions) { chat in
                    TabItemView(
                        title: app.ask.title(for: chat), icon: .symbol(PaneGlyph.chat),
                        isActive: app.ask.selectedID == chat.id,
                        isRunning: app.ask.isRunning(chat.id),
                        isAtPaneEdge: app.ask.sessions.first?.id == chat.id,
                        isRenaming: renaming == chat.id,
                        editableTitle: app.ask.title(for: chat), canClose: true,
                        closeTitle: "Close conversation",
                        onSelect: { Task { await app.ask.select(chat.id) } },
                        onStartRename: { renaming = chat.id },
                        onCommitRename: { title in
                            renaming = nil
                            Task { await app.ask.rename(chat.id, title: title) }
                        },
                        onCancelRename: { renaming = nil },
                        onClose: { app.ask.requestClose(chat.id) },
                        namespace: selection
                    )
                    .id(chat.id)
                }
            }
        } append: {
            Button { Task { await app.ask.newConversation() } } label: {
                Image(systemName: "plus")
                    .font(Typo.labelEmphasis)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: Metrics.barHeight, height: Metrics.barHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHoverChange { isNewTabHovered = $0 }
            .background {
                if isNewTabHovered {
                    RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                        .fill(Palette.hover)
                        .padding(Metrics.spacingTight)
                }
            }
            .help("New Ask Bloom conversation")
            .accessibilityLabel("New Ask Bloom conversation")
        } trailing: {
            EmptyView()
        }
    }
}
