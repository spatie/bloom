import SwiftUI
import BloomCore

/// One bare glyph in the browser pane's bar.
///
/// `.accessoryBar` is the system's own style for a row of small controls along the edge of a pane,
/// and it brings one hit box, one hover fill and one pressed state to the whole set.
///
/// The disabled colour stays explicit, because a foreground style set here is one `.accessoryBar`
/// will not dim on its own. At `Palette.textTertiary` a dead Back arrow was a shade off the live
/// Forward arrow beside it and read as pressable; `Palette.textDisabled` is the system's answer
/// for a control that is there and cannot be pressed.
struct BrowserToolbarButton: View {
    var control: BrowserToolbar.Control
    var action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Label(control.name, systemImage: control.symbol)
                .labelStyle(.iconOnly)
                .foregroundStyle(control.isEnabled ? Palette.textSecondary : Palette.textDisabled)
        }
        .buttonStyle(.accessoryBar)
        .disabled(!control.isEnabled)
        .help(control.help)
    }
}

/// The browser pane's toolbar: where you have been, where you are, and who else gets the page.
///
/// Its own view rather than a method on `BrowserTabView` so that a fixture can draw it. The pane
/// needs a live `BrowserSession` behind it, which owns a `WKWebView`, and a gallery page can
/// neither make one nor photograph it. See `BrowserToolbarGallery`.
///
/// **Three groups, which is the anatomy every Mac browser's bar has.** Back and forward joined in
/// one capsule; the address in a capsule of its own, with the connection glyph at one end and
/// Reload at the other; then the two glyphs that hand this page to somebody else, bare. There is
/// no stock component for any of it, and `BrowserToolbar` says why: the toolbar, the joined pair
/// and the search item are all `NSWindow`'s, and this is a pane inside a split inside a tab.
///
/// Two notes this file used to carry are overturned by that, both knowingly. The pair had no
/// plate, because `surfaceRaised` means *switched on* in this window and a fill round two of five
/// glyphs would have read that way; it cannot now, since the pair and the field wear the same fill
/// and the same radius, so the bar reads as two raised controls beside three bare glyphs. And the
/// camera has crossed the field, because with Reload inside the field what is left on the right is
/// the two controls that take this page elsewhere.
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

    /// Drawn inside the field's own edge rather than outside it, so the bar does not have to give
    /// the ring clearance. See `HomeBar.focusRingWidth`.
    private static let focusRingWidth: CGFloat = 2

    /// Somebody has the field, so it shows the string they are editing rather than a split of it.
    private var isEditing: Bool { addressFocus.wrappedValue }

    /// How the address is drawn when nobody is typing into it. The rule is in the core, because
    /// which run of the string is the host is the one thing here that can be got dangerously
    /// wrong. See `BrowserAddressDisplay`.
    private var display: BrowserAddressDisplay { .of(address) }

    var body: some View {
        HStack(spacing: Metrics.spacingWide) {
            navigation
            addressField
            BrowserToolbarButton(control: toolbar.screenshot, action: capture)
            BrowserShareButton(control: toolbar.share, shareable: toolbar.shareable)
        }
        .padding(.horizontal, Metrics.spacingSmall)
        .frame(height: Metrics.barHeight)
        .background(Palette.surfaceSunken)
    }

    /// The pair, as one control with a divider through it, which is what `NSToolbarItemGroup`
    /// draws for Safari and what nothing in a pane can ask for.
    private var navigation: some View {
        HStack(spacing: 0) {
            BrowserToolbarButton(control: toolbar.back, action: goBack)
                .modifier(HistoryMenu(entries: backHistory, go: goToHistory))
            Hairline(axis: .vertical)
            BrowserToolbarButton(control: toolbar.forward, action: goForward)
                .modifier(HistoryMenu(entries: forwardHistory, go: goToHistory))
        }
        .frame(height: Metrics.controlHeight)
        .background(Palette.surfaceRaised)
        // Before the border, so the clip takes the hover fills of the two buttons and not the
        // stroke, which `strokeBorder` already draws inside the edge.
        .clipShape(Capsule())
        .overlay { Capsule().strokeBorder(Palette.border, lineWidth: Metrics.hairline) }
    }

    private var addressField: some View {
        HStack(spacing: Metrics.spacingSmall) {
            // Never while the field is being typed into: a lock beside a string somebody is
            // halfway through entering is a lock making a promise about nothing.
            if !isEditing, let symbol = display.security.symbol {
                Image(systemName: symbol)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .help(display.security.help ?? "")
                    .accessibilityLabel(display.security.help ?? "")
            }
            field
            BrowserToolbarButton(control: toolbar.reload, action: reloadOrStop)
        }
        .padding(.leading, Metrics.spacing)
        .padding(.trailing, Metrics.spacingTight)
        .frame(height: Metrics.controlHeight)
        .background(alignment: .leading) { fill }
        .clipShape(Capsule())
        .overlay {
            Capsule().strokeBorder(
                isRingVisible ? Palette.focusRing : Palette.border,
                lineWidth: isRingVisible ? Self.focusRingWidth : Metrics.hairline
            )
        }
    }

    /// The field's ground, with the load behind it.
    ///
    /// `Palette.selected` rather than a tint: it is the step of Bloom's ramp meant to sit under
    /// content in a list that has not got the keyboard, which is exactly what is wanted behind a
    /// line of text, and it keeps the accent out of a bar that has nothing else tinted in it.
    @ViewBuilder private var fill: some View {
        Palette.surfaceRaised
        if let progress = toolbar.progress {
            GeometryReader { proxy in
                Palette.selected.frame(width: proxy.size.width * progress)
            }
            .animation(Motion.pane, value: progress)
        }
    }

    /// **The real field is always here, and the two-tone address is drawn over it.**
    ///
    /// Swapping a `Text` in for the `TextField` was the other way round, and it costs the field
    /// everything AppKit does for it: a click lands on the label, so focus has to be set by hand,
    /// and with it go caret placement, drag selection and select-all on focus. Hidden text with a
    /// label over it keeps all of that, because what is clicked is still the field.
    private var field: some View {
        ZStack(alignment: .leading) {
            TextField("Address", text: $address)
                .textFieldStyle(.plain)
                .font(Typo.label)
                .focused(addressFocus)
                .autocorrectionDisabled()
                .foregroundStyle(isEditing ? Palette.textPrimary : .clear)
                .onSubmit(submit)

            // Nothing over an empty field, so the placeholder is the one AppKit draws.
            if !isEditing, !display.isEmpty {
                addressLabel.allowsHitTesting(false)
            }
        }
    }

    private var addressLabel: some View {
        (Text(display.leading).foregroundStyle(Palette.textTertiary)
            + Text(display.host).foregroundStyle(Palette.textPrimary)
            + Text(display.trailing).foregroundStyle(Palette.textTertiary))
            .lineLimit(1)
            // The tail, which is where a query string lives. The host is the part worth reading
            // and it is at the head, so it is the part that always survives the cut.
            .truncationMode(.tail)
            .font(Typo.label)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The pages an arrow can jump past, under a right click on it.
///
/// The one affordance that most makes a pair of arrows read as a browser's: a reader four links
/// deep asks to go back to the page they started on, not to click Back four times. Right click
/// only. Safari opens the same menu on a press and hold, and there is no way to ask a SwiftUI
/// `Button` for that without rebuilding the control in AppKit, which would cost this bar the
/// system style every control in it is drawn with.
///
/// A modifier rather than a `.contextMenu` written twice, because SwiftUI will happily open a
/// blank menu on an arrow whose history is empty, so the whole thing is left off instead.
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
