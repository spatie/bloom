import SwiftUI
import BloomCore

/// The magnifying glass in the title bar, which opens the search panel.
///
/// **Twenty-six points of glyph where there were two hundred and six of glass.** The window's
/// search was an `NSSearchToolbarItem` contributed by `.searchable`: a capsule with the system's
/// drop shadow, packed against the trailing end of the toolbar by a flexible spacer, sharing an
/// edge with nothing. The shadow and the glass were macOS 26's and could not be turned off while
/// the item was a toolbar item. This is the same search, in chrome that fits what it actually
/// does.
///
/// **It is a `WindowPaneToggle` in everything but name**, drawn on the same 32 point slot with the
/// same hover plate and the same quiet ink, because it sits directly beside the inspector's toggle
/// and two controls an inch apart that are drawn differently read as two unrelated things. It is
/// not that type because that type says whether a pane is open, and this opens a card that closes
/// itself.
///
/// **A glyph and not the field, and something is lost with it.** A field in a toolbar teaches
/// itself and a panel behind a key does not; this is the mitigation and it is only a partial one.
/// What it does keep is that the search is still visible to somebody who has never pressed Cmd+K.
struct SearchToolbarButton: View {
    var action: @MainActor () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label("Search", systemImage: "magnifyingglass")
                .labelStyle(.iconOnly)
                .font(Typo.labelEmphasis)
                .foregroundStyle(Palette.textSecondary)
                // Inside the label, which is the whole of the bug `WindowPaneToggle` records: a
                // `.plain` Button takes its clicks inside its label, so a frame around the
                // finished Button only centres a glyph-sized target in a 32 point box.
                .frame(width: Metrics.barHeight, height: Metrics.barHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHoverChange { isHovered = $0 }
        .background {
            if isHovered {
                RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                    .fill(Palette.hover)
                    .padding(Metrics.spacingTight)
            }
        }
        .accessibilityLabel("Search")
        .help("Search workspaces, transcripts and commands")
    }
}
