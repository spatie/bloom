import SwiftUI
import BloomCore

/// One button in the browser pane's bar.
///
/// **`.accessoryBar`, which is what the rest of this app's strips of small controls already use.**
/// `SidebarStatusBar` and `InspectorLayout.inspectorBarControl` both reached for it and both wrote
/// down why: it is the system's own style for a row of small controls along the edge of a pane, it
/// brings one hit box, one hover fill and one pressed state to the whole set, and it leaves the
/// glyph at label weight where `.borderless` draws it in the accent colour. This bar was the last
/// one in the window still hand rolling that with a fixed frame and two foreground colours, which
/// is exactly the "app's approximation of a Mac control" the pane is meant to stop looking like.
///
/// The disabled colour stays explicit. `.accessoryBar` dims a disabled label, but the browser's
/// arrows are disabled most of the time on a fresh page, and `Palette.textTertiary` is the rung
/// this window uses for a control that is there and cannot be pressed.
struct BrowserToolbarButton: View {
    var control: BrowserToolbar.Control
    var action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Label(control.name, systemImage: control.symbol)
                .labelStyle(.iconOnly)
                .foregroundStyle(control.isEnabled ? Palette.textSecondary : Palette.textTertiary)
        }
        .buttonStyle(.accessoryBar)
        .disabled(!control.isEnabled)
        .help(control.help)
    }
}

/// The browser pane's toolbar: what you do to the page, where the page is, and the share sheet.
///
/// Its own view rather than a method on `BrowserTabView` so that it can be drawn from a fixture.
/// The pane's toolbar needs a live `BrowserSession` behind it, which owns a `WKWebView`, and a
/// gallery page can neither make one nor photograph it. See `BrowserToolbarGallery`.
///
/// **Left to right: back, forward, reload or stop, the camera, the address, share.** That is
/// Safari's order, with the two exceptions this app has reasons for. The camera is left of the
/// address with the other things you do to the page, which is `BrowserTabView`'s own note and
/// still holds. Share is right of the address because that is where every Mac browser puts it: the
/// controls left of the field move you between pages, and the ones right of it hand the page you
/// are on to something else.
struct BrowserToolbarView: View {
    var toolbar: BrowserToolbar
    /// What the field shows, which is not where the page is. See `BrowserTabView.address`.
    @Binding var address: String
    var addressFocus: FocusState<Bool>.Binding
    /// Whether the ring should be drawn at all: focused, and in the window the keys are going to.
    var isRingVisible: Bool
    /// The pages behind and ahead of this one, nearest first, named by `BrowserToolbar`.
    var backHistory: [BrowserToolbar.HistoryEntry] = []
    var forwardHistory: [BrowserToolbar.HistoryEntry] = []

    var goBack: @MainActor () -> Void = {}
    var goForward: @MainActor () -> Void = {}
    /// Somewhere further back or further forward than one step, by the distance on the entry.
    var goToHistory: @MainActor (Int) -> Void = { _ in }
    var reloadOrStop: @MainActor () -> Void = {}
    var capture: @MainActor () -> Void = {}
    var submit: @MainActor () -> Void = {}

    /// Drawn inside the field's own edge rather than outside it, so the toolbar does not have to
    /// give the ring clearance. See `HomeBar.focusRingWidth`.
    private static let focusRingWidth: CGFloat = 2

    var body: some View {
        HStack(spacing: Metrics.spacing) {
            // **The pair, joined by air rather than by a plate.** Safari draws back and forward as
            // one control with a shared background, and the honest way to say that here is the
            // spacing scale: nothing is between these two and a group's worth of it is on either
            // side, which is what `Metrics.spacing` and `spacingWide` are named for. A shared fill
            // was tried on paper and rejected: `Palette.surfaceRaised` is this window's raised
            // control, meaning a selected segment or a chip, so a filled pill around two of the
            // five glyphs in this bar would read as the pair being switched on. The bar has one
            // filled thing in it and it is the address field, which is a place to type.
            HStack(spacing: 0) {
                BrowserToolbarButton(control: toolbar.back, action: goBack)
                    .modifier(HistoryMenu(entries: backHistory, go: goToHistory))
                BrowserToolbarButton(control: toolbar.forward, action: goForward)
                    .modifier(HistoryMenu(entries: forwardHistory, go: goToHistory))
            }

            BrowserToolbarButton(control: toolbar.reload, action: reloadOrStop)

            // Left of the address rather than right of it, with the other three: they are all
            // things you do to the page, and the address field is where the page is. Its own group
            // on the right would have read as belonging to the field.
            BrowserToolbarButton(control: toolbar.screenshot, action: capture)

            addressField

            BrowserShareButton(control: toolbar.share, shareable: toolbar.shareable)
        }
        .padding(.horizontal, Metrics.spacingSmall)
        .frame(height: Metrics.barHeight)
        .background(Palette.surfaceSunken)
    }

    private var addressField: some View {
        TextField("Address", text: $address)
            .textFieldStyle(.plain)
            .font(Typo.label)
            .focused(addressFocus)
            .autocorrectionDisabled()
            .padding(.horizontal, Metrics.spacingWide)
            .padding(.vertical, Metrics.spacingSmall)
            .background(Palette.surfaceRaised, in: .rect(cornerRadius: Metrics.cornerSmall))
            // A hand-built field gets no focus ring from AppKit, and an address bar that looks
            // identical whether or not it has the keyboard is the single most reliable way to make
            // a Mac window feel like a web page. The same overlay `HomeBar`'s search field uses, in
            // the same colour macOS draws a real one in, so it follows Full Keyboard Access and
            // Increase Contrast with it.
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                    .strokeBorder(
                        isRingVisible ? Palette.focusRing : Palette.border,
                        lineWidth: isRingVisible ? Self.focusRingWidth : Metrics.hairline
                    )
            }
            .onSubmit(submit)
    }
}

/// The pages an arrow can jump past, under a right click on it.
///
/// The one affordance that most makes a pair of arrows read as a browser's rather than as two
/// buttons: a reader who has clicked four links deep asks to go back to the page they started on,
/// not to click Back four times. Right click only. Safari opens the same menu on a press and hold
/// as well, and there is no way to ask a SwiftUI `Button` for that without rebuilding the control
/// in AppKit, which would cost this bar the system style every other control in it is drawn with.
///
/// A modifier rather than a `.contextMenu` written twice, because an empty menu is a menu: SwiftUI
/// will happily open a blank one on an arrow whose history is empty, so the whole thing is left off
/// instead. That is never a control losing a menu it had, since an arrow with no history behind it
/// is an arrow that cannot be pressed either.
private struct HistoryMenu: ViewModifier {
    var entries: [BrowserToolbar.HistoryEntry]
    var go: @MainActor (Int) -> Void

    func body(content: Content) -> some View {
        if entries.isEmpty {
            content
        } else {
            content.contextMenu {
                ForEach(entries) { entry in
                    Button(entry.name) { go(entry.id) }
                }
            }
        }
    }
}
