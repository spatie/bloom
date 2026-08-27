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
/// **The pair and the field are real glass.** It was refused once on the grounds that glass
/// samples an arbitrary web page, and that was wrong: `BrowserTabView` is a `VStack(spacing: 0)`,
/// so this bar sits above the page rather than over it. What the two shapes sample is the bar's
/// own `surfaceSunken`, which is ours.
///
/// The camera and Share stay `.accessoryBar` rather than taking `.buttonStyle(.glass)`. Four
/// raised capsules in a row is a bar with no groups left in it, and Safari's own two are bare
/// glyphs until the pointer is on them. The camera is on that side because with Reload inside the
/// field, what is left on the right is the pair that takes this page elsewhere.
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
        // One sampling pass for the two shapes rather than two, which is what the container is
        // for. `spacing: 0` because the other thing it does is merge shapes that come within a
        // distance of each other, and the capsule and the pill running together into one blob is
        // exactly what the three groups above must not become.
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: Metrics.spacingWide) {
                navigation
                addressField
                BrowserToolbarButton(control: toolbar.screenshot, action: capture)
                BrowserShareButton(control: toolbar.share, shareable: toolbar.shareable)
            }
        }
        .padding(.horizontal, Metrics.spacingSmall)
        .frame(height: Metrics.barHeight)
        // The bar itself is a colour and not glass. What is behind it is `Palette.surface`, one
        // flat fill, so the material would resolve to a colour Bloom already has a name for, and
        // it would lift the ground the two shapes above sample. Its bottom edge also meets the
        // page's top edge, where a ground that moves reads as a seam rather than as material.
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
        // Clipped before the glass, not after it. `glassEffect` shapes only its own background, so
        // the two hover fills still need this to stop at the capsule.
        .clipShape(Capsule())
        // `.interactive()` here and nowhere else in the bar: this shape is nothing but controls,
        // and the material answering the pointer is what separates glass from a picture of it.
        // Which arrow is under the pointer is still said by `.accessoryBar`'s own fill inside.
        .glassEffect(.regular.interactive(), in: Capsule())
        // The rim is drawn rather than left to the material's, because it is what still says where
        // the capsule ends once Reduce Transparency has turned the glass opaque.
        .overlay { Capsule().strokeBorder(Palette.border, lineWidth: Metrics.outline) }
    }

    private var addressField: some View {
        HStack(spacing: Metrics.spacingSmall) {
            // Never while the field is being typed into: a lock beside a string somebody is
            // halfway through entering is a lock making a promise about nothing.
            if !isEditing, let symbol = display.security.symbol {
                Image(systemName: symbol)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiaryOnGlass)
                    .help(display.security.help ?? "")
                    .accessibilityLabel(display.security.help ?? "")
            }
            field
            BrowserToolbarButton(control: toolbar.reload, action: reloadOrStop)
        }
        .padding(.leading, Metrics.spacing)
        .padding(.trailing, Metrics.spacingTight)
        .frame(height: Metrics.controlHeight)
        .background(alignment: .leading) { load }
        .clipShape(Capsule())
        // `.regular` and not `.interactive()`. This is where a caret is put, and a material that
        // lifts and settles on the way to placing one reads as fidgety rather than alive. Both
        // controls in the pill keep their own hover fills.
        .glassEffect(.regular, in: Capsule())
        .overlay {
            Capsule().strokeBorder(
                isRingVisible ? Palette.focusRing : Palette.border,
                lineWidth: isRingVisible ? Self.focusRingWidth : Metrics.outline
            )
        }
    }

    /// How far the page has got, over the glass and under the address.
    ///
    /// `Palette.selected` rather than a tint: it is the step of Bloom's ramp meant to sit under
    /// content in a list that has not got the keyboard, which is exactly what is wanted behind a
    /// line of text, and it keeps the accent out of a bar that has nothing else tinted in it.
    ///
    /// Opaque, so the material stops where the load has reached. A wash the glass carried through
    /// would be a progress fill you have to look for, which is the one thing it must not be.
    @ViewBuilder private var load: some View {
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

    private func tinted(_ string: String, _ colour: Color) -> Text {
        Text(string).foregroundStyle(colour)
    }

    /// The dim half of the two-tone, named here only so the interpolation below fits on a line.
    private var dim: Color { Palette.textTertiaryOnGlass }

    /// The dim runs are `textTertiaryOnGlass`, which is Bloom's tertiary in light and AppKit's
    /// secondary label in dark. **The two halves differ because the ground does.** Glass lifts a
    /// flat backdrop toward white, and in light this bar is already all but white, so the tertiary
    /// holds 4.56 to 1 and nothing is wrong; in dark the same lift takes it from 5.65 through the
    /// 4.5 floor at 8 percent to 2.98 at 20. Retuning one pair cannot cover both, because an ink
    /// still clearing 4.5 on a quarter-lifted dark ground stands 1.32 to 1 off `labelColor` where
    /// the tertiary stands 2.21: the floor gets bought by deleting the two-tone. See
    /// `Palette.textTertiaryOnGlass` and `PaletteContrastTests.aLiftedGroundCostsTheTertiaryInk`.
    ///
    /// The connection glyph takes the same ink rather than the bar's `textSecondary`, so the dim
    /// half of the address stays one weight. Its floor is a glyph's 3, and the tertiary misses
    /// even that in dark, at 2.98.
    private var addressLabel: some View {
        // Interpolated rather than concatenated: `Text.+` is deprecated in macOS 26 and the app
        // target builds with -warnings-as-errors.
        Text("\(tinted(display.leading, dim))\(tinted(display.host, Palette.textPrimary))\(tinted(display.trailing, dim))")
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
