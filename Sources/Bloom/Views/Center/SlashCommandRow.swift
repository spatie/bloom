import SwiftUI
import BloomCore

/// One command in the slash menu: what it is called, what it does, and which of its characters the
/// query hit. A real button, so it answers to VoiceOver and to a click on any part of the row
/// rather than only where the text happens to be.
struct SlashCommandRow: View {
    var match: SlashCommandMatch
    var isSelected: Bool
    var onPick: @MainActor () -> Void
    var onHover: @MainActor () -> Void

    @Environment(\.controlActiveState) private var activeState

    @State private var isHovered = false

    private var command: SlashCommand { match.command }

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: Metrics.spacing) {
                name
                    .font(Typo.code)
                    .lineLimit(1)
                    .layoutPriority(1)

                if !command.detail.isEmpty {
                    Text(command.detail)
                        .font(Typo.label)
                        .foregroundStyle(
                            isEmphasized
                                ? Palette.selectedEmphasizedText.opacity(0.75)
                                : Palette.textTertiary
                        )
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 0)

                if let badge = command.badge {
                    Chip(text: badge)
                }
            }
            .padding(.horizontal, Metrics.spacing)
            .frame(height: Metrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("/\(command.name)")
        // Focused, because this menu really is driven by the arrow keys while the composer
        // holds the keyboard, which is the one case AppKit paints in the accent.
        .rowBackground(isSelected: isSelected, isHovered: isHovered, isFocused: true)
        .onHover { hovering in
            isHovered = hovering
            if hovering { onHover() }
        }
    }

    /// The name, with the characters the query actually matched carried at full weight and colour
    /// and the rest stepped back.
    ///
    /// Ranges rather than characters, so a run reads as a word: typing `revi` lights the `revi`
    /// inside `security-review` rather than the stray `r` of `secu(r)ity`, because the matcher
    /// reports the run it scored rather than the first letters it could reach.
    private var name: Text {
        var text = Text("/").foregroundStyle(quiet)
        guard !match.highlights.isEmpty else {
            return text + Text(command.name).foregroundStyle(loud)
        }

        let characters = Array(command.name)
        let hits = Set(match.highlights)
        var index = 0
        while index < characters.count {
            let isHit = hits.contains(index)
            var end = index
            while end < characters.count, hits.contains(end) == isHit { end += 1 }
            let run = Text(String(characters[index..<end]))
            text = text + (isHit ? run.fontWeight(.bold).foregroundStyle(loud) : run.foregroundStyle(quiet))
            index = end
        }
        return text
    }

    private var loud: Color {
        isEmphasized ? Palette.selectedEmphasizedText : Palette.textPrimary
    }

    private var quiet: Color {
        isEmphasized ? Palette.selectedEmphasizedText.opacity(0.65) : Palette.textSecondary
    }

    /// See `FileMentionRow`: the labels set their own colour, so they have to know when the row
    /// underneath them has gone accent coloured or they stay unreadable on it.
    private var isEmphasized: Bool {
        isSelected && activeState != .inactive
    }
}
