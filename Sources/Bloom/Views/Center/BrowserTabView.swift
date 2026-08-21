import SwiftUI

/// A browser tab: an address bar over a page.
///
/// It exists so the dev server a workspace is running can be looked at without leaving the window
/// the agent is working in, which is the whole reason a workspace gets a port of its own.
struct BrowserTabView: View {
    var tab: CenterTab
    /// The menu the pane this tab is filling offers, which the page puts under its own. Handed
    /// down rather than reached for, for the reason `ToolPaneView.splitColumn` is: only the pane
    /// above knows which pane it is.
    var paneMenu: (@MainActor () -> NSMenu)?

    /// What the field shows, which is not where the page is. Typing has to be allowed to disagree
    /// with the page until Return is pressed, so this is local state and the session is only told
    /// on submit.
    @State private var address = ""
    @FocusState private var isAddressFocused: Bool

    /// Drawn inside the field's own edge rather than outside it, so the toolbar does not have to
    /// give the ring clearance. See `HomeBar.focusRingWidth`.
    private static let focusRingWidth: CGFloat = 2

    private var tabs: CenterTabStore { .shared }
    private var session: BrowserSession { tabs.browser(for: tab) }

    var body: some View {
        let session = self.session

        VStack(spacing: 0) {
            toolbar(session)
            Hairline()
            BrowserWebView(session: session, paneMenu: paneMenu)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Palette.surface)
        // Per tab, so switching between two browser tabs puts each field back where its own page
        // is rather than leaving the address of the one that was showing a moment ago.
        //
        // A tab with no address at all takes the keyboard into the field. That is what splitting
        // into a browser makes: the pane opens on nothing, because nobody has said where it should
        // go, and the toolbar is then the only thing in it that means anything. Without this the
        // pane reads as a blank rectangle with a dead search box over it, and the user has to work
        // out that the box is the point and click it. A tab that has somewhere to be does not take
        // focus, so the `+` menu's browser still opens on the dev server without stealing the
        // keyboard off the composer next to it.
        .task(id: tab.id) {
            address = session.displayAddress
            if address.isEmpty { isAddressFocused = true }
        }
        .onChange(of: session.currentURL) {
            // The page navigated on its own: a link, a redirect, a router. The field follows it,
            // unless the user is in the middle of typing a different address into it.
            if !isAddressFocused { address = session.displayAddress }
            tabs.setURL(session.displayAddress, for: tab)
        }
    }

    private func toolbar(_ session: BrowserSession) -> some View {
        HStack(spacing: Metrics.spacing) {
            control("chevron.backward", title: "Back", enabled: session.canGoBack, action: session.goBack)
            control(
                "chevron.forward", title: "Forward",
                enabled: session.canGoForward, action: session.goForward
            )
            control(
                session.isLoading ? "xmark" : "arrow.clockwise",
                title: session.isLoading ? "Stop" : "Reload",
                enabled: true
            ) {
                if session.isLoading { session.webView.stopLoading() } else { session.reload() }
            }

            TextField("Address", text: $address)
                .textFieldStyle(.plain)
                .font(Typo.label)
                .focused($isAddressFocused)
                .autocorrectionDisabled()
                .padding(.horizontal, Metrics.spacingWide)
                .padding(.vertical, Metrics.spacingSmall)
                .background(Palette.surfaceRaised, in: .rect(cornerRadius: Metrics.cornerSmall))
                // A hand-built field gets no focus ring from AppKit, and an address bar that looks
                // identical whether or not it has the keyboard is the single most reliable way to
                // make a Mac window feel like a web page. The same overlay `HomeBar`'s search field
                // uses, in the same colour macOS draws a real one in, so it follows Full Keyboard
                // Access and Increase Contrast with it.
                .overlay {
                    RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                        .strokeBorder(
                            isAddressFocused ? Palette.focusRing : Palette.border,
                            lineWidth: isAddressFocused ? Self.focusRingWidth : Metrics.hairline
                        )
                }
                .onSubmit {
                    session.load(address)
                    isAddressFocused = false
                }
        }
        .padding(.horizontal, Metrics.inset)
        .frame(height: Metrics.barHeight)
        .background(Palette.surfaceSunken)
    }

    private func control(
        _ symbol: String,
        title: String,
        enabled: Bool,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(Typo.label)
                .foregroundStyle(enabled ? Palette.textSecondary : Palette.textTertiary)
                .frame(width: Metrics.rowHeight, height: Metrics.glyph)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(title)
    }
}
