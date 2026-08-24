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
                        // Each row's identity is the thing it names, never its position.
                        // These rows carried `.id(index)` for the scroll target below, and that
                        // pinned identity to a slot in a lazy stack: when the ranked list changed
                        // under an open menu, the stack kept serving the views it had cached for
                        // those slots, so typing `/re` showed the rows the bare `/` had ranked,
                        // alphabetical, `compact` among them, while the real matches were only in
                        // the model. The pick then honoured the model, and picked a command that
                        // was not the row on screen. Identity by what the row shows makes a
                        // changed list a changed row, which a lazy container does rebuild.
                                .id(match.id)
                            }
                        }
                        .padding(Metrics.spacingSmall)
                    }
                    .frame(maxHeight: maxHeight)
                    // No anchor, so the arrow keys scroll the least they can get away with.
                    // Pinning to the bottom threw the highlighted row to the far edge every time
                    // the user stepped upwards, which no Mac menu does.
                    .onChange(of: selectedIndex) { _, index in
                        guard matches.indices.contains(index) else { return }
                        proxy.scrollTo(matches[index].id)
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
