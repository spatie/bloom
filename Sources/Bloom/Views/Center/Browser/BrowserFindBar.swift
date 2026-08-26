import SwiftUI
import BloomCore

/// Find in Page, drawn where a browser puts it: a banner between the toolbar and the page.
///
/// **A banner rather than a floating panel**, for the reason the rest of this pane gives: a
/// browser tab is already one pane of a split centre column, and a panel hovering inside one is a
/// second window nobody asked for. It pushes the page down by a row while it is up, which is what
/// Safari's does.
///
/// **`Cmd G` and `Shift Cmd G` are on the two arrows** rather than only on the menu bar, because
/// the bar being on screen is exactly the state in which those keys mean stepping this search. A
/// key equivalent on a button reaches only as far as the view hierarchy holding it, so they are
/// claimed while the bar is up and given back the moment it closes. `BrowserPageWebView` claims
/// the same two while the page holds the keyboard, and `BrowserFindCommand` is the one mapping
/// both routes read, so the two cannot come to disagree.
struct BrowserFindBar: View {
    var find: BrowserFind
    var focus: FocusState<Bool>.Binding
    var type: @MainActor (String) -> Void
    var step: @MainActor (BrowserFindCommand) -> Void
    var done: @MainActor () -> Void

    /// The field's own text. Local, so a keystroke draws immediately rather than waiting on the
    /// search behind it, in the same shape and for the same reason as the address field above.
    @State private var query = ""

    var body: some View {
        HStack(spacing: Metrics.spacingWide) {
            Image(systemName: "magnifyingglass")
                // The size the composer's search field draws the same mark at. Left at the default
                // it was a 13 point glyph leading a strip set in caption and micro.
                .imageScale(.small)
                .foregroundStyle(Palette.textTertiary)
                .frame(width: Metrics.glyph)

            field

            if !find.status.isEmpty {
                Text(find.status)
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textTertiary)
            }

            BrowserToolbarButton(
                control: BrowserFindBar.previous(find), action: { step(.previous) }
            )
            .keyboardShortcut("g", modifiers: [.command, .shift])

            BrowserToolbarButton(control: BrowserFindBar.next(find), action: { step(.next) })
                .keyboardShortcut("g", modifiers: .command)

            Button("Done", action: done)
                .buttonStyle(.accessoryBar)
                .font(Typo.caption)
        }
        .padding(.horizontal, Metrics.spacingSmall)
        .frame(height: Metrics.barHeight)
        .background(Palette.surfaceSunken)
        .overlay(alignment: .bottom) { Hairline() }
        .task(id: find.opens) {
            // On every open rather than on the first, so a second Cmd F puts the caret back in the
            // field and selects what is there, which is what the key does everywhere else.
            query = find.query
            focus.wrappedValue = true
        }
    }

    private var field: some View {
        TextField("Find on page", text: $query)
            .textFieldStyle(.plain)
            .font(Typo.label)
            .focused(focus)
            .autocorrectionDisabled()
            .frame(maxWidth: 220)
            .onChange(of: query) { type(query) }
            .onSubmit { step(.next) }
            // Escape closes the banner, which is what it does in every find bar on the platform.
            .onExitCommand(perform: done)
    }

    /// The two arrows, described the way the toolbar above describes its own, so a disabled one
    /// here and a disabled Back up there are the same grey and the same shape.
    private static func previous(_ find: BrowserFind) -> BrowserToolbar.Control {
        BrowserToolbar.Control(
            symbol: "chevron.up",
            name: "Find Previous",
            help: "Go to the previous match",
            isEnabled: find.canStep
        )
    }

    private static func next(_ find: BrowserFind) -> BrowserToolbar.Control {
        BrowserToolbar.Control(
            symbol: "chevron.down",
            name: "Find Next",
            help: "Go to the next match",
            isEnabled: find.canStep
        )
    }
}
