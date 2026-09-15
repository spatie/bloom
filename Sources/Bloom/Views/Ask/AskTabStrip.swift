import SwiftUI
import BloomCore

struct AskTabStrip: View {
    /// Which conversations sweep, resolved by `AskView` alongside its own top edge.
    var busy: BusySignalPlacement<SessionID>

    @Environment(AppModel.self) private var app
    @State private var renaming: SessionID?
    @Namespace private var selection

    var body: some View {
        TabStrip(tabCount: app.ask.sessions.count, selection: app.ask.selectedID) {
            EmptyView()
        } tabs: {
            HStack(spacing: 0) {
                ForEach(Array(app.ask.sessions.enumerated()), id: \.element.id) { index, chat in
                    if index > 0 {
                        // Hidden against a selected or busy capsule, as the centre strip does. See
                        // `TabStripDividers`, which this strip has no drag or hover to feed.
                        TabStripSeparator(isHidden: TabStripDividers.visible(
                            in: [app.ask.sessions[index - 1].id, chat.id],
                            selected: app.ask.selectedID, hovered: nil, dragged: nil,
                            busy: [app.ask.sessions[index - 1].id, chat.id].filter(busy.showsInTab)
                        ) == [false])
                    }
                    TabItemView(
                        title: app.ask.title(for: chat), icon: .symbol(PaneGlyph.chat),
                        isActive: app.ask.selectedID == chat.id,
                        isRunning: busy.showsInTab(chat.id),
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
                Label("New conversation", systemImage: "plus")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.regular)
            .buttonSizing(.flexible)
            .frame(width: TabItemView.tabHeight, height: TabItemView.tabHeight)
            .frame(width: Metrics.barHeight, height: Metrics.barHeight)
            .help("New Ask Bloom conversation")
            .accessibilityLabel("New Ask Bloom conversation")
        } trailing: {
            EmptyView()
        }
    }
}
