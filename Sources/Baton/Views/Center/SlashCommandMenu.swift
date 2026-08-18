import SwiftUI

/// The panel that drops above the composer once the draft is a lone `/command`.
///
/// Rendering only. The composer owns the selection and the key handling, because its text view
/// never gives up first responder while the menu is open.
struct SlashCommandMenu: View {
    var commands: [SlashCommand]
    var query: String
    var selectedIndex: Int
    var onPick: @MainActor (SlashCommand) -> Void
    var onHighlight: @MainActor (Int) -> Void = { _ in }

    var body: some View {
        MenuPanel {
            if commands.isEmpty {
                MenuEmptyRow(
                    text: query.isEmpty
                        ? "No commands in ~/.claude/commands or .claude/commands"
                        : "No command matches /\(query)"
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                                SlashCommandRow(
                                    command: command,
                                    isSelected: index == selectedIndex,
                                    onPick: { onPick(command) },
                                    onHover: { onHighlight(index) }
                                )
                                .id(index)
                            }
                        }
                        .padding(Metrics.spacingSmall)
                    }
                    .frame(maxHeight: MenuLayout.maxHeight)
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
}
