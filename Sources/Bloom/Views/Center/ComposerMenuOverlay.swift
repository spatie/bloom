import SwiftUI
import BloomCore

/// Whichever completion menu the draft has asked for, floating over the composer.
struct ComposerMenuOverlay: View {
    var menu: ComposerMenu
    var commands: [SlashCommandMatch]
    var commandsAreLoaded: Bool
    var files: [FileMatch]
    var selectedIndex: Int
    /// What the room on the menu's side of the box allows, already decided by the composer's
    /// placement rule. See `MenuLayout.placement`.
    var maxHeight: CGFloat
    var onPickCommand: @MainActor (SlashCommand) -> Void
    var onPickFile: @MainActor (FileMatch) -> Void
    var onHighlight: @MainActor (Int) -> Void

    var body: some View {
        switch menu {
        case .slash(let query):
            SlashCommandMenu(
                matches: commands,
                query: query,
                isLoaded: commandsAreLoaded,
                selectedIndex: selectedIndex,
                maxHeight: maxHeight,
                onPick: onPickCommand,
                onHighlight: onHighlight
            )
        case .mention(let token):
            FileMentionMenu(
                matches: files,
                query: token.query,
                selectedIndex: selectedIndex,
                maxHeight: maxHeight,
                onPick: onPickFile,
                onHighlight: onHighlight
            )
        case .none:
            EmptyView()
        }
    }
}
