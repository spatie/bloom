import SwiftUI
import AppKit
import BloomCore

/// One terminal tab, carved into as many shells as the user has asked for.
///
/// Panes are positioned absolutely from the frames the split tree computes rather than by nesting
/// stacks the way the tree nests. Two reasons, both of which matter here: a nested layout would
/// have to be built out of `AnyView` because the view type would be recursive, and every reshape
/// would move a live `LocalProcessTerminalView` into a different superview. Flat means each pane
/// keeps its place in the hierarchy however the tree is rearranged around it.
///
/// Nothing here owns a shell. A pane is an id, and `TerminalSessionStore` hands back the same live
/// terminal for that id for as long as the app runs.
struct TerminalSplitView: View {
    /// The tab these panes belong to. It is also the id of the first pane, so a tab that has never
    /// been split keeps the shell it had before splitting existed.
    var ownerID: String
    var workspace: Workspace
    var repo: Repo?
    var port: Int
    /// Called when the user closes the last pane, which is the tab asking to go away.
    var onCloseTab: @MainActor () -> Void

    /// The same switch the terminal itself reads, so turning the Ghostty theme off also turns off
    /// Ghostty's way of fading the panes that do not have the keyboard.
    @AppStorage(TerminalGhostty.defaultsKey) private var usesGhosttyTheme = true

    private var splits: TerminalSplitStore { .shared }

    /// What a split takes out of the space its two panes share. One point, because the strip the
    /// pointer aims at is drawn over the panes rather than reserved between them.
    private static let dividerThickness: Double = 1

    /// What a shell keeps from the edge of its pane. SwiftTerm draws its first glyph on the view's
    /// own edge, so without this the prompt sits flush against the divider beside it.
    private static let paneInset: CGFloat = Metrics.spacingSmall

    var body: some View {
        // Read here rather than inside the `GeometryReader`, so the dependency on the store is
        // registered while this body is being tracked. A read that only happens in the layout pass
        // is a redraw that only happens by luck.
        let layout = splits.layout(for: ownerID)
        let focusRequest = splits.focusRequest(for: ownerID)

        return GeometryReader { proxy in
            let geometry = layout.geometry(in: proxy.size, dividerThickness: Self.dividerThickness)

            ZStack(alignment: .topLeading) {
                // A pty forked into a zero rectangle has to be resized the moment it exists, and
                // its first prompt is drawn at a width nothing else will ever have, so the panes
                // wait for the first real layout pass instead.
                if proxy.size.width > 1, proxy.size.height > 1 {
                    ForEach(geometry.panes, id: \.pane) { item in
                        pane(item.pane, in: layout, focusRequest: focusRequest)
                            .frame(width: item.frame.width, height: item.frame.height)
                            .position(x: item.frame.midX, y: item.frame.midY)
                    }

                    ForEach(geometry.dividers, id: \.path) { divider in
                        SplitPaneDivider(
                            axis: divider.axis,
                            ratio: divider.ratio,
                            span: divider.span,
                            length: divider.axis == .horizontal
                                ? divider.frame.height
                                : divider.frame.width,
                            color: dividerColor
                        ) { ratio in
                            splits.setRatio(ratio, at: divider.path, in: ownerID)
                        }
                        .position(x: divider.frame.midX, y: divider.frame.midY)
                    }
                }
            }
        }
        .background(Palette.surfaceSunken)
    }

    private func pane(_ id: String, in layout: SplitLayout, focusRequest: Int) -> some View {
        let isFocused = layout.focus == id

        return TerminalView(
            tab: TerminalTab(id: id, workspaceID: workspace.id, title: "Terminal"),
            workspace: workspace,
            repo: repo,
            port: port,
            isFocusedPane: isFocused,
            focusRequest: focusRequest,
            onFocus: { splits.focus(id, in: ownerID) },
            onCommand: { handle($0, from: id) },
            onContextMenu: {
                TerminalPaneMenu.make(
                    canClose: layout.paneCount > 1,
                    isZoomed: layout.zoomed == id
                ) { _ = handle($0, from: id) }
            }
        )
        .padding(Self.paneInset)
        .overlay {
            if !isFocused && layout.paneCount > 1 { dimming }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isFocused ? "Terminal pane, focused" : "Terminal pane")
    }

    /// How a pane without the keyboard is quietened.
    ///
    /// Ghostty's two dimming keys are honoured: a user who has already told one terminal how far
    /// to fade an unfocused split has said everything Bloom needs to know. Painting the fill at the
    /// complement of the opacity is the same arithmetic as drawing the pane at that opacity over
    /// the fill, and it leaves the terminal view itself opaque, which is what keeps a translucent
    /// window from showing through the text.
    private var dimming: some View {
        let ghostty = usesGhosttyTheme ? TerminalGhostty.splitAppearance() : GhosttySplitAppearance()
        let opacity = ghostty.unfocusedOpacity ?? 0.8
        let fill = ghostty.unfocusedFill.map { Color(nsColor: NSColor($0)) } ?? Palette.surfaceSunken

        return fill
            .opacity(1 - opacity)
            .allowsHitTesting(false)
    }

    /// Ghostty's `split-divider-color` when the user set one, and the rule every other pane
    /// boundary in the window is drawn in when they did not.
    private var dividerColor: Color {
        guard usesGhosttyTheme, let color = TerminalGhostty.splitAppearance().dividerColor else {
            return Palette.border
        }
        return Color(nsColor: NSColor(color))
    }

    /// A keystroke that reached a shell. Returning false hands the key back to the app menu, which
    /// is what keeps Cmd+Option+Up stepping through workspaces from a pane with nothing above it.
    private func handle(_ command: TerminalPaneCommand, from pane: String) -> Bool {
        // The keystroke came from whichever shell has first responder, and that is the truth about
        // where the user is, whatever the layout last recorded.
        splits.focus(pane, in: ownerID)

        switch command {
        case .split(let axis):
            return splits.split(ownerID, axis: axis) != nil

        case .focus(let direction):
            return splits.moveFocus(direction, in: ownerID)

        case .close:
            guard splits.close(pane: pane, in: ownerID) else {
                // The last pane, so there is no tab left to show. Whoever owns the strip takes it
                // from here, and closing the tab is what stops the shell.
                onCloseTab()
                return true
            }
            TerminalSessionStore.shared.closePane(id: pane)
            return true

        case .toggleZoom:
            return splits.toggleZoom(in: ownerID)
        }
    }
}
