import SwiftUI
import BloomCore

/// Where the panel sits, what happens to the window behind it, and when its list is rebuilt.
///
/// **The window is dimmed and it does not move.** Spotlight and Raycast float over the screen;
/// VS Code and Sublime pin their panel to the top of the window, and that is what this is, because
/// the panel acts on this window's contents. Dimmed rather than blurred: a blur costs a live
/// backdrop filter over the whole window for a card that is up for two seconds, and what the dim
/// has to say is only "this is in front".
///
/// **Clicking outside closes it, and nothing is lost.** The click is taken by the dim rather than
/// by the window under it, so the pointer cannot select a sidebar row on its way out of the panel.
struct SearchPanelOverlay: ViewModifier {
    let app: AppModel
    @Bindable var panel: SearchPanelModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far below the top of the window the card hangs.
    ///
    /// Near the top rather than against it: a card flush with the title bar reads as part of the
    /// chrome, and this is a thing in front of the window rather than a thing attached to it.
    private static let topInset: CGFloat = 56

    /// Enough to say the window behind is not the thing being used, and not so much that a person
    /// cannot read the workspace name they were looking at. Black in both appearances, because
    /// what it does is take light out of the ground rather than tint it.
    private static let dim = 0.22

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if panel.isOpen {
                    ZStack(alignment: .top) {
                        Color.black.opacity(Self.dim)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture { panel.close(app: app) }
                            .accessibilityHidden(true)

                        SearchPanelView(app: app, panel: panel)
                            .padding(.top, Self.topInset)
                    }
                    .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : Motion.pane, value: panel.isOpen)
            // Home's list must not take the keyboard off a field somebody is typing in, and this
            // is the flag it reads. The panel's field is a field in the window exactly as the
            // toolbar's was. See `HomeListKeyboard`.
            .onChange(of: panel.isOpen) { _, open in
                app.isSearchFieldFocused = open
            }
            // The list is rebuilt when its inputs move rather than while drawing, which is the
            // same rule Home's `rebuild` keeps and for the same reason: it runs over every
            // workspace on the machine.
            .onChange(of: app.workspaces) { _, _ in panel.rebuild(app: app) }
            .onChange(of: app.repos) { _, _ in panel.rebuild(app: app) }
            .onChange(of: app.transcriptResults) { _, _ in panel.rebuild(app: app) }
            // The two halves of the running state, watched separately because they move
            // separately: a turn starting and a turn stopping to ask are different moments, and
            // both change what the resting list leads with.
            .onChange(of: app.runningWorkspaceIDs) { _, _ in panel.rebuild(app: app) }
            .onChange(of: app.waitingWorkspaceIDs) { _, _ in panel.rebuild(app: app) }
    }
}

extension View {
    /// The panel, over this window.
    func searchPanel(app: AppModel) -> some View {
        modifier(SearchPanelOverlay(app: app, panel: SearchPanelModel.shared))
    }
}
