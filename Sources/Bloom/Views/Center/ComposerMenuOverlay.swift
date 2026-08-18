import SwiftUI

/// Whichever completion menu the draft has asked for, floating above the composer.
struct ComposerMenuOverlay: View {
    var menu: ComposerMenu
    var commands: [SlashCommand]
    var files: [FileMatch]
    var selectedIndex: Int
    var onPickCommand: @MainActor (SlashCommand) -> Void
    var onPickFile: @MainActor (FileMatch) -> Void
    var onHighlight: @MainActor (Int) -> Void

    var body: some View {
        switch menu {
        case .slash(let query):
            SlashCommandMenu(
                commands: commands,
                query: query,
                selectedIndex: selectedIndex,
                onPick: onPickCommand,
                onHighlight: onHighlight
            )
        case .mention(let token):
            FileMentionMenu(
                matches: files,
                query: token.query,
                selectedIndex: selectedIndex,
                onPick: onPickFile,
                onHighlight: onHighlight
            )
        case .none:
            EmptyView()
        }
    }
}
