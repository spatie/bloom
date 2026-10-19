import SwiftUI
import BloomCore

/// The chat and tool panes of one project-free conversation. A conversation uses its own directory
/// for shells and local browser pages, while its tabs and split ratios belong to its session id.
struct ConversationColumnView: View {
    let sessionID: SessionID

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var renamingID: ConversationPaneID?
    @Namespace private var selection

    private var state: ConversationPaneState? { app.ask.paneState(for: sessionID) }

    var body: some View {
        Group {
            if let state {
                let tabs = state.layout.tabs
                VStack(spacing: 0) {
                    if tabs.count > 1 {
                        tabStrip(tabs, state: state)
                            .transition(.opacity)
                    }
                    ConversationPanesView(state: state, sessionID: sessionID)
                }
                .animation(reduceMotion ? nil : Motion.pane, value: tabs.count > 1)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.windowBackground)
        .task(id: sessionID) {
            await app.ask.open()
            await app.ask.select(sessionID)
        }
    }

    private func tabStrip(_ tabs: [ConversationLayout.Tab], state: ConversationPaneState) -> some View {
        TabStrip(tabCount: tabs.count, selection: AnyHashable(state.layout.selectedTabID)) {
            EmptyView()
        } tabs: {
            HStack(spacing: 0) {
                ForEach(tabs) { tab in
                    TabItemView(
                        title: title(of: tab),
                        icon: .symbol(symbol(of: tab)),
                        isActive: state.layout.selectedTabID == tab.id,
                        isRenaming: renamingID == tab.id,
                        editableTitle: title(of: tab),
                        canClose: tab.id != ConversationLayout.chatID,
                        closeTitle: title(of: tab),
                        onSelect: { state.select(tab.id) },
                        onStartRename: { renamingID = tab.id },
                        onCommitRename: { title in
                            if tab.id == ConversationLayout.chatID {
                                Task { await app.ask.rename(sessionID, title: title) }
                            } else {
                                state.rename(title, tabID: tab.id)
                            }
                            renamingID = nil
                        },
                        onCancelRename: { renamingID = nil },
                        onClose: { state.closeTab(tab.id) },
                        namespace: selection
                    )
                    .id(tab.id)
                }
            }
        } append: {
            EmptyView()
        } trailing: {
            EmptyView()
        }
    }

    private func title(of tab: ConversationLayout.Tab) -> String {
        guard tab.id == ConversationLayout.chatID else { return tab.title }
        return app.ask.sessions.first(where: { $0.id == sessionID }).map(app.ask.title(for:)) ?? tab.title
    }

    private func symbol(of tab: ConversationLayout.Tab) -> String {
        switch tab.panes[ConversationPaneID(tab.layout.focus)]?.kind ?? .chat {
        case .chat: PaneGlyph.chat
        case .terminal: PaneGlyph.terminal
        case .browser: PaneGlyph.browser
        }
    }
}

private struct ConversationPanesView: View {
    let state: ConversationPaneState
    let sessionID: SessionID

    var body: some View {
        let tab = state.layout.selectedTab
        let layout = tab?.layout ?? SplitLayout(pane: ConversationLayout.chatID.rawValue)

        GeometryReader { proxy in
            let geometry = layout.geometry(in: proxy.size, dividerThickness: CentrePaneMeasure.dividerThickness)
            ZStack(alignment: .topLeading) {
                if let tab, proxy.size.width > 1, proxy.size.height > 1 {
                    ForEach(geometry.panes, id: \.pane) { item in
                        if let pane = tab.pane(ConversationPaneID(item.pane)) {
                            ConversationPaneView(
                                state: state, sessionID: sessionID, tabID: tab.id,
                                pane: pane, isSplit: layout.paneCount > 1
                            )
                            .frame(width: item.frame.width, height: item.frame.height)
                            .clipped()
                            .position(x: item.frame.midX, y: item.frame.midY)
                        }
                    }
                    ForEach(geometry.dividers, id: \.path) { divider in
                        SplitPaneDivider(
                            axis: divider.axis,
                            ratio: divider.ratio,
                            span: divider.span,
                            length: divider.axis == .horizontal
                                ? divider.frame.height : divider.frame.width,
                            color: Palette.border,
                            onChange: { state.setRatio($0, at: divider.path, in: tab.id) },
                            onChangeEnded: { state.persistRatio() }
                        )
                        .position(x: divider.frame.midX, y: divider.frame.midY)
                    }
                }
            }
        }
        .background(Palette.windowBackground)
    }
}

private struct ConversationPaneView: View {
    let state: ConversationPaneState
    let sessionID: SessionID
    let tabID: ConversationPaneID
    let pane: ConversationLayout.Pane
    let isSplit: Bool

    private var closeColumn: (@MainActor () -> Void)? {
        guard isSplit else { return nil }
        return { state.closePane(tabID: tabID, paneID: pane.id) }
    }

    var body: some View {
        Group {
            switch pane.kind {
            case .chat:
                AskConversationContent(sessionID: sessionID)
            case .terminal:
                TerminalSplitView(
                    ownerID: pane.id.rawValue,
                    owner: .conversation(sessionID, directory: state.directory),
                    onCloseTab: { state.closePane(tabID: tabID, paneID: pane.id) },
                    closeColumn: closeColumn,
                    splitColumn: { axis, kind in
                        state.split(tabID: tabID, paneID: pane.id, axis: axis, kind: kind.conversationKind)
                    },
                    terminalLabel: pane.title
                )
            case .browser:
                ConversationBrowserPane(state: state, tabID: tabID, pane: pane, isSplit: isSplit)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .simultaneousGesture(TapGesture().onEnded { state.focus(pane.id, in: tabID) })
        .contextMenu {
            if pane.kind != .terminal && pane.kind != .browser {
                CenterPaneMenu(
                    isSplit: isSplit,
                    split: { axis, kind in
                        state.split(tabID: tabID, paneID: pane.id, axis: axis, kind: kind.conversationKind)
                    },
                    close: { state.closePane(tabID: tabID, paneID: pane.id) }
                )
            }
        }
    }
}
