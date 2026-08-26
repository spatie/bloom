import SwiftUI
import BloomCore

/// A browser tab: an address bar over a page.
///
/// It exists so the dev server a workspace is running can be looked at without leaving the window
/// the agent is working in, which is the whole reason a workspace gets a port of its own.
struct BrowserTabView: View {
    /// Whose conversation a snapshot of this page is attached to, and whose worktree it is written
    /// into. A browser tab belongs to a workspace, so there is never a question of which.
    @Bindable var model: WorkspaceModel
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
    /// The find banner's field, held here rather than in the banner because a `FocusState` belongs
    /// to the view that stays on screen: the banner is added and removed, and a focus binding torn
    /// down with it would never settle.
    @FocusState private var isFindFocused: Bool

    /// True from the press until the picture is in the composer. It is normally a tenth of a
    /// second, and it is not always: `takeSnapshot` waits for the page to finish laying out, and
    /// then the file is written into the worktree off the main actor. A second press in the middle
    /// of that would attach the same page twice, so the button goes quiet rather than counting.
    @State private var isCapturing = false

    @Environment(AppModel.self) private var app

    /// See `ControlActiveState.showsFocusRing`: a ring belongs in the key window only.
    @Environment(\.controlActiveState) private var activeState

    private var tabs: CenterTabStore { .shared }
    private var session: BrowserSession { tabs.browser(for: tab) }

    /// Focused, and in the window the keys are going to.
    private var isRingVisible: Bool { isAddressFocused && activeState.showsFocusRing }

    var body: some View {
        let session = self.session

        VStack(spacing: 0) {
            toolbar(session)
            Hairline()
            if session.find.isShowing {
                BrowserFindBar(
                    find: session.find,
                    focus: $isFindFocused,
                    type: session.typeInFind,
                    step: session.perform,
                    done: { session.perform(.hide) }
                )
            }
            if !session.downloads.isEmpty {
                BrowserDownloadsBar(
                    downloads: session.downloads, clear: session.clearDownloads
                )
            }
            BrowserWebView(session: session, paneMenu: pageMenu, host: host)
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
            // A pane redrawn onto a session that has been loading all along, which is what
            // switching workspace and coming back is. Nothing changed while this view was gone,
            // so no `onChange` will fire, and without this the strip would sit on the host until
            // the reader navigated.
            tabs.setPage(session.page, for: tab)
        }
        // The page and the address travel together, so the strip is told once. Two `onChange`
        // bodies, one per fact, put the title and the navigation that brought it in an order
        // nothing promises. See `CenterTabStore.setPage`.
        .onChange(of: session.page) {
            // The page navigated on its own: a link, a redirect, a router. The field follows it,
            // unless the user is in the middle of typing a different address into it.
            if !isAddressFocused { address = session.displayAddress }
            tabs.setPage(session.page, for: tab)
        }
    }

    /// What the bar offers, given what the page can do. Every one of those answers is
    /// `BrowserToolbar` in the core, so this view holds no rule of its own: it wires the buttons
    /// to the session and draws what it is told. See `BrowserToolbarView`.
    private func toolbar(_ session: BrowserSession) -> some View {
        BrowserToolbarView(
            toolbar: BrowserToolbar(
                page: session.page,
                canGoBack: session.canGoBack,
                canGoForward: session.canGoForward,
                isLoading: session.isLoading,
                loadProgress: session.loadProgress,
                isCapturing: isCapturing
            ),
            address: $address,
            addressFocus: $isAddressFocused,
            isRingVisible: isRingVisible,
            backHistory: session.backHistory,
            forwardHistory: session.forwardHistory,
            goBack: session.goBack,
            goForward: session.goForward,
            goToHistory: { session.go(back: $0) },
            reloadOrStop: {
                if session.isLoading { session.webView.stopLoading() } else { session.reload() }
            },
            capture: capture,
            submit: {
                session.load(address)
                isAddressFocused = false
            }
        )
    }

    /// What the page in this pane may ask the window for.
    ///
    /// Built here rather than on the session because this is the level that knows which workspace
    /// the tab belongs to, and a session must not learn that: it outlives every view that draws it.
    /// The model is captured weakly, so a browser tab left open on a workspace nobody has selected
    /// for an hour is not what keeps that workspace's model alive.
    private var host: BrowserPaneHost {
        BrowserPaneHost(
            openTab: { [weak model] url in
                guard let model else { return }
                BrowserTab.openWindow(url, in: model)
            },
            report: { [weak app] notice in
                app?.alert = BloomAlert(title: notice.title, message: notice.message)
            }
        )
    }

    // MARK: - Screenshot

    /// Takes the page as it is on screen and puts it in the composer, in one press.
    ///
    /// **One press, with no confirmation.** The alternative, a sheet asking where the picture
    /// should go or whether to send it, would put two clicks and a decision in front of something
    /// whose whole value is that it is faster than reaching for the screenshot key. It is also
    /// undoable in the place that matters: the picture arrives as a word in the draft, so Command+Z
    /// takes it back out and nothing has been sent to anybody.
    ///
    /// **It does not send the turn.** Nobody wants an agent handed a screenshot with no sentence
    /// attached. What lands is an attachment and a caret, and the user writes what is wrong with it.
    private func capture() {
        guard !isCapturing else { return }
        isCapturing = true
        Task {
            defer { isCapturing = false }
            let session = self.session
            let data: Data
            do {
                data = try await session.snapshot()
            } catch {
                app.alert = BloomAlert(
                    title: "That page could not be captured",
                    message: error.readableMessage
                )
                return
            }

            let taken = Set(
                PromptAttachmentStore.shared
                    .attachments(for: model.activeSession?.id.rawValue ?? "")
                    .map(\.filename)
            )
            let name = BrowserSnapshot.filename(for: session.displayAddress, avoiding: taken)
            let outcome = await ComposerHandoff.attach(
                [.image(data, format: .png, named: name)], to: model
            )
            guard let failure = outcome.failure else { return }
            app.alert = BloomAlert(title: "That screenshot was not attached", message: failure)
        }
    }

    /// The pane's own menu with what Bloom can do with this page on top of it, which is what a
    /// right click on the page ends up showing under WebKit's Reload and Inspect Element.
    ///
    /// The camera in the toolbar was the only way to reach the screenshot. A toolbar glyph with no
    /// word next to it is discoverable by hovering it and reading the help tag, which is to say
    /// discoverable by accident, and the right click is where a Mac user asks what can be done with
    /// the thing under the pointer. Neither item is a menu bar item, because both act on one page
    /// in one pane and the menu bar cannot say which page.
    ///
    /// **These two are one group, above the pane's own.** WebKit's items act on the page, these
    /// act on the page, and Split Right and Close Pane act on the pane, so the separators the
    /// reader ends up with divide it that way. Opening elsewhere leads, because it is the one item
    /// here that hands the page to something outside Bloom.
    ///
    /// Built fresh on every click, like the pane menu it wraps. Either item is dropped rather than
    /// greyed when it has nothing to act on, which is what Close Pane does one group down: no
    /// address to open, no Open in External Browser, and a capture already running takes the
    /// screenshot out for the reason the toolbar button goes quiet, which is that a second press
    /// in the middle of the first would attach the same page twice.
    private func pageMenu() -> NSMenu {
        let menu = paneMenu?() ?? NSMenu()

        var items: [NSMenuItem] = []
        // Never the raw address. What may be handed to another application is `BrowserAddress`'s
        // decision, because the string was written by the page.
        if let url = BrowserAddress.external(from: session.displayAddress) {
            // The same words the transcript's link menu uses for the same destination. See
            // `TranscriptLinkMenu`.
            items.append(item("Open in External Browser") { NSWorkspace.shared.open(url) })
        }
        if !isCapturing {
            // The same words as the toolbar's own camera, taken from the one place that says them,
            // so the glyph and the menu item cannot drift into naming the same thing two ways.
            items.append(item(BrowserToolbar().screenshot.name, perform: capture))
        }
        guard !items.isEmpty else { return menu }

        if !menu.items.isEmpty { menu.insertItem(.separator(), at: 0) }
        for (offset, item) in items.enumerated() { menu.insertItem(item, at: offset) }
        return menu
    }

    /// An item that runs a closure.
    ///
    /// The target is hung off the item's `representedObject` as well as its `target`, because
    /// `NSMenuItem` holds its target weakly and represented objects strongly, and the menu is the
    /// only thing alive by the time the item is clicked. See `BrowserPageWebView` for what happens
    /// to these items next.
    private func item(
        _ title: String, perform: @escaping @MainActor () -> Void
    ) -> NSMenuItem {
        let target = PageMenuTarget(perform: perform)
        let item = NSMenuItem(
            title: title, action: #selector(PageMenuTarget.fire), keyEquivalent: ""
        )
        item.target = target
        item.representedObject = target
        return item
    }

}

/// What answers an item of the page menu. A closure cannot be an `NSMenuItem` action, and the view
/// that built the item is a struct that will not be there when the item is clicked.
@MainActor
final class PageMenuTarget: NSObject {
    private let perform: @MainActor () -> Void

    init(perform: @escaping @MainActor () -> Void) {
        self.perform = perform
    }

    @objc func fire() {
        perform()
    }
}
