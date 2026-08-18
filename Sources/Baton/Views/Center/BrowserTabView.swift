import SwiftUI

/// A browser tab: an address bar over a page.
///
/// It exists so the dev server a workspace is running can be looked at without leaving the window
/// the agent is working in, which is the whole reason a workspace gets a port of its own.
struct BrowserTabView: View {
    var tab: CenterTab

    /// What the field shows, which is not where the page is. Typing has to be allowed to disagree
    /// with the page until Return is pressed, so this is local state and the session is only told
    /// on submit.
    @State private var address = ""
    @FocusState private var isAddressFocused: Bool

    private var tabs: CenterTabStore { .shared }
    private var session: BrowserSession { tabs.browser(for: tab) }

    var body: some View {
        let session = self.session

        VStack(spacing: 0) {
            toolbar(session)
            Hairline()
            BrowserWebView(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Palette.surface)
        // Per tab, so switching between two browser tabs puts each field back where its own page
        // is rather than leaving the address of the one that was showing a moment ago.
        .task(id: tab.id) { address = session.displayAddress }
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
                .overlay {
                    RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                        .strokeBorder(Palette.border, lineWidth: Metrics.hairline)
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
