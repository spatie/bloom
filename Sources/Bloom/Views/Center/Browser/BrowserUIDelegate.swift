import AppKit
import WebKit
import BloomCore

/// The things a page asks the application for, rather than the network: a window of its own, a
/// question put to the reader, and a file off this Mac.
///
/// **A browser pane had no `WKUIDelegate` at all**, and WebKit's answer to a missing one is to do
/// nothing without saying so. Every `target="_blank"` link and every `window.open` returned null
/// and left the reader looking at a page where a click had visibly failed; `alert` drew nothing,
/// `confirm` was always false and `prompt` was always null, so a page that waited for the reader
/// to agree to something waited for ever; every `<input type="file">` opened no panel. For a pane
/// whose whole job is the dev server running in the worktree next door, those are the everyday
/// cases rather than the exotic ones.
///
/// Kept off `BrowserSession` for the reason `NavigationObserver` is: `uiDelegate` is the sort of
/// reference that outlives what it points at, and a separate object makes the weak link back
/// explicit. It is one object per session, so a delegate is never shared between two pages.
///
/// ## What this does not implement, on purpose
///
/// Adopting a UI delegate is adopting a list of things a page may ask for, and the ones left out
/// are left out deliberately. `requestMediaCapturePermissionFor` is absent, so a page still cannot
/// reach the camera or the microphone: WebKit denies capture when the delegate does not answer,
/// and this pane is the owner's own browser logged in as him. `webViewDidClose` is absent because
/// nothing here ever hands WebKit a web view it created, so no page has a window of its own to
/// close. The argument behind both is the head of `BrowserPaneCommand`: a page asking for
/// something is not a page being granted whatever it likes.
@MainActor
final class BrowserUIObserver: NSObject, WKUIDelegate {
    weak var owner: BrowserSession?

    // MARK: - A window of its own

    /// `target="_blank"` and `window.open`.
    ///
    /// **Nil is returned and a Bloom browser tab is opened instead, which is a decision rather
    /// than a shortcut.** The other answer is to hand WebKit a real second `WKWebView` in a panel
    /// of its own, which is the only way `window.opener` and `postMessage` keep working, and which
    /// is what an OAuth popup wants. It was not taken: a floating panel is not a thing this window
    /// has anywhere else, it would sit above the pane the reader is working in with no tab strip,
    /// no address field and no way to split it, and a page could put one there without a click.
    /// A browser tab is what every other route into this column produces, it is closable,
    /// nameable, splittable and inspectable like any other, and it is the answer the reader can
    /// already reason about. What it costs is honest and worth stating: a sign-in popup that
    /// expects to talk back to its opener will not, because the tab is not its opener.
    ///
    /// **In front, because the reader asked for it by name**, which is the same argument
    /// `BrowserTab.open` writes down. A link that opened a page behind the one you were reading
    /// reads as having done nothing, which is the bug this method exists to fix.
    ///
    /// **A new tab rather than the workspace's existing browser**, which is the one place this
    /// disagrees with `BrowserTab.open`. That one is a reader choosing an address out of a
    /// transcript and not wanting a tab per link; this is a page that has said the current
    /// document should stay where it is, and pointing the pane it asked from at somewhere else
    /// would be the one outcome the page has ruled out.
    ///
    /// How many a page may have is `BrowserPopups`, in the core, where it can be tested.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        owner?.openWindow(navigationAction.request.url)
        return nil
    }

    // MARK: - The page's own questions

    /// `alert`.
    ///
    /// **The `async` spelling of all three, and that is the safety property rather than a
    /// nicety.** WebKit hands each of these a completion handler that gives the page's JavaScript
    /// its answer back: never calling it hangs the page for ever, and calling it twice raises.
    /// Written this way the compiler resumes the caller exactly once whatever path the method
    /// returns by, including the one where the pane is closed while the sheet is up, which
    /// `BrowserDialogPresenter.dismiss` turns into an ordinary cancel.
    ///
    /// Nothing is returned to the page by `alert`, so the answer is dropped. It is still awaited,
    /// because the page is entitled to be blocked until the reader has read it: that is what
    /// `alert` means, and a page that carried on regardless would put its next dialog up over this
    /// one.
    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async {
        _ = await owner?.ask(.alert, message: message, from: Self.name(of: frame.securityOrigin))
    }

    /// `confirm`. False for a cancel, and false for a page that has been silenced or has no window
    /// to ask in, which is the answer a page must already be ready for.
    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async -> Bool {
        let answer = await owner?.ask(
            .confirm, message: message, from: Self.name(of: frame.securityOrigin)
        )
        return answer?.isConfirmed ?? false
    }

    /// `prompt`. Nil for a cancel, which is what a browser returns and what a page tests for.
    ///
    /// An empty string is a different answer from nil and is preserved: a reader who clears the
    /// field and presses OK has said "nothing", and a page that treats that as a cancel is a page
    /// making its own mistake.
    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo
    ) async -> String? {
        let answer = await owner?.ask(
            .prompt,
            message: prompt,
            defaultText: defaultText ?? "",
            from: Self.name(of: frame.securityOrigin)
        )
        return answer?.text
    }

    // MARK: - A file off this Mac

    /// `<input type="file">`.
    ///
    /// **The `async` spelling of the delegate method rather than the completion handler.** WebKit
    /// hangs the file input forever if the handler is never called and calls `NSInternalInconsistencyException`
    /// if it is called twice, and neither of those can happen here: the compiler resumes the
    /// continuation exactly once whatever path this returns by.
    ///
    /// `NSOpenPanel.present` rather than `runModal`, for the reason that extension gives: a modal
    /// run loop stops every other workspace's transcript from streaming for as long as the panel
    /// is open, and this is an app whose whole point is several agents working at once.
    ///
    /// WebKit only asks this after a click on the input, so there is no new reach here for a page
    /// that nobody is looking at. What the reader chooses is readable by the page, which is what
    /// choosing a file in any browser means.
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo
    ) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canCreateDirectories = false
        panel.prompt = "Upload"
        panel.message = BrowserPageOrigin.uploadMessage(
            from: Self.name(of: frame.securityOrigin),
            allowsMultiple: parameters.allowsMultipleSelection
        )
        guard await panel.present() == .OK else { return nil }
        return panel.urls
    }

    /// The page's origin as a name, which is Bloom's half of anything a page raises. The rule is
    /// `BrowserPageOrigin` in the core; this is only the three properties off WebKit's own type.
    private static func name(of origin: WKSecurityOrigin) -> String? {
        BrowserPageOrigin.name(scheme: origin.protocol, host: origin.host, port: origin.port)
    }
}
