import SwiftUI
import BloomCore

/// The panel that opens over the composer once the draft is a lone `/command`.
///
/// Rendering only. The composer owns the selection and the key handling, because its text view
/// never gives up first responder while the menu is open.
struct SlashCommandMenu: View {
    var matches: [SlashCommandMatch]
    var query: String
    var isLoaded: Bool
    var selectedIndex: Int
    /// What the room on the menu's side of the composer allows. The default is the cap a menu
    /// keeps even with a whole transcript above it.
    var maxHeight: CGFloat = MenuLayout.maxHeight
    var onPick: @MainActor (SlashCommand) -> Void
    var onHighlight: @MainActor (Int) -> Void = { _ in }

    var body: some View {
        MenuPanel {
            if matches.isEmpty {
                MenuEmptyRow(text: emptyText)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(matches.enumerated()), id: \.element.id) { index, match in
                                SlashCommandRow(
                                    match: match,
                                    isSelected: index == selectedIndex,
                                    onPick: { onPick(match.command) },
                                    onHover: { onHighlight(index) }
                                )
                                .id(index)
                            }
                        }
                        .padding(Metrics.spacingSmall)
                    }
                    .frame(maxHeight: maxHeight)
                    // No anchor, so the arrow keys scroll the least they can get away with.
                    // Pinning to the bottom threw the highlighted row to the far edge every time
                    // the user stepped upwards, which no Mac menu does.
                    .onChange(of: selectedIndex) { _, index in
                        proxy.scrollTo(index)
                    }
                }
            }
        }
    }

    /// Three different nothings, and they call for three different sentences. The first scan has
    /// not landed yet; there is genuinely nothing installed; or there is plenty and none of it
    /// matches what was typed. Since the catalogue now covers commands, skills and every enabled
    /// plugin, the middle one is close to unreachable and the last one is what a user will
    /// actually meet.
    private var emptyText: String {
        guard isLoaded else { return "Looking for commands\u{2026}" }
        guard !query.isEmpty else {
            return "No commands, skills or plugins found for Claude Code"
        }
        return "No command matches /\(query)"
    }
}
