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

    /// True from the press until the picture is in the composer. It is normally a tenth of a
    /// second, and it is not always: `takeSnapshot` waits for the page to finish laying out, and
    /// then the file is written into the worktree off the main actor. A second press in the middle
    /// of that would attach the same page twice, so the button goes quiet rather than counting.
    @State private var isCapturing = false

    @Environment(AppModel.self) private var app

    /// See `ControlActiveState.showsFocusRing`: a ring belongs in the key window only.
    @Environment(\.controlActiveState) private var activeState

    /// Drawn inside the field's own edge rather than outside it, so the toolbar does not have to
    /// give the ring clearance. See `HomeBar.focusRingWidth`.
    private static let focusRingWidth: CGFloat = 2

    private var tabs: CenterTabStore { .shared }
    private var session: BrowserSession { tabs.browser(for: tab) }

    /// Focused, and in the window the keys are going to.
    private var isRingVisible: Bool { isAddressFocused && activeState.showsFocusRing }

    var body: some View {
        let session = self.session

        VStack(spacing: 0) {
            toolbar(session)
            Hairline()
            BrowserWebView(session: session, paneMenu: pageMenu)
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

            // Left of the address rather than right of it, with the other three: they are all
            // things you do to the page, and the address field is where the page is. Its own group
            // on the right would have read as belonging to the field.
            control(
                "camera",
                title: "Send a Screenshot to the Agent",
                enabled: !isCapturing,
                action: capture
            )

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
                            isRingVisible ? Palette.focusRing : Palette.border,
                            lineWidth: isRingVisible ? Self.focusRingWidth : Metrics.hairline
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

    /// The pane's own menu with the screenshot on top of it, which is what a right click on the
    /// page ends up showing under WebKit's Reload and Inspect Element.
    ///
    /// The camera in the toolbar was the only way to reach this. A toolbar glyph with no word next
    /// to it is discoverable by hovering it and reading the help tag, which is to say discoverable
    /// by accident, and the right click is where a Mac user asks what can be done with the thing
    /// under the pointer. It is not a menu bar item because it acts on one page in one pane, and
    /// the menu bar cannot say which page.
    ///
    /// Built fresh on every click, like the pane menu it wraps, and dropped while a capture is
    /// already running for the reason the toolbar button goes quiet: a second press in the middle
    /// of the first would attach the same page twice.
    ///
    /// The target is hung off the item's `representedObject` as well as its `target`, because
    /// `NSMenuItem` holds its target weakly and represented objects strongly, and the menu is the
    /// only thing alive by the time the item is clicked. See `BrowserPageWebView` for what happens
    /// to these items next.
    private func pageMenu() -> NSMenu {
        let menu = paneMenu?() ?? NSMenu()
        guard !isCapturing else { return menu }

        let title = "Send a Screenshot to the Agent"
        let target = SnapshotMenuTarget(perform: capture)
        let item = NSMenuItem(
            title: title, action: #selector(SnapshotMenuTarget.fire), keyEquivalent: ""
        )
        item.target = target
        item.representedObject = target

        if !menu.items.isEmpty { menu.insertItem(.separator(), at: 0) }
        menu.insertItem(item, at: 0)
        return menu
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

/// What answers the page menu's screenshot item. A closure cannot be an `NSMenuItem` action, and
/// the view that built the item is a struct that will not be there when the item is clicked.
@MainActor
final class SnapshotMenuTarget: NSObject {
    private let perform: @MainActor () -> Void

    init(perform: @escaping @MainActor () -> Void) {
        self.perform = perform
    }

    @objc func fire() {
        perform()
    }
}
