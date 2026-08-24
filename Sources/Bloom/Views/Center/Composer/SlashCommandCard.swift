import SwiftUI
import BloomCore

/// The card that floats over the composer while the pointer rests on a command chip.
///
/// The nil case is handled in here rather than with an `if let` at the call site, for the reason
/// spelled out on `AttachmentCardOverlay`: an alignment guide set inside an `if` in an overlay's
/// builder is not honoured, and the card ends up drawn over the composer instead of above it.
struct SlashCommandCardOverlay: View {
    var name: String?
    var command: SlashCommand?
    var availableWidth: CGFloat
    var availableHeight: CGFloat

    var body: some View {
        if let name {
            SlashCommandCard(
                name: name,
                command: command,
                availableWidth: availableWidth,
                availableHeight: availableHeight
            )
        }
    }
}

/// What a command is, in three parts: what it is called, the one line it describes itself with,
/// and the head of what it actually tells the agent to do.
///
/// The same `MenuPanel` and the same measurements as `AttachmentCard`, because it appears in the
/// same place above the same box and a second material there would read as a different app.
///
/// The frontmatter is not shown. A skill's `description` is often a paragraph, and printed twice
/// (once as the description line, once as the first lines of the file) it would fill the card with
/// itself. See `SlashCommandIndex.documentation`.
struct SlashCommandCard: View {
    var name: String
    var command: SlashCommand?
    /// What the composer has to give, which is what the card may take.
    var availableWidth: CGFloat
    /// The room on whichever side of the composer the card opens on. A card taller than this does
    /// not overflow, it is clipped, and what gets clipped is the name and the description, which
    /// is the half a reader looks at first. So the prose is cut to fit instead.
    var availableHeight: CGFloat

    /// The same box `AttachmentCard` takes.
    private static let maxWidth: CGFloat = 520
    /// Fewer lines than the file preview reads, and the reason is the header this card has and
    /// that one does not. A hover card grows upwards from the composer, so every line of it comes
    /// out of the conversation the reader is answering: at the file preview's twenty four the name
    /// and the description went off the top of the sheet and the card was all prose and no
    /// heading. Sixteen leaves the whole thing on screen with the path still under it.
    private static let lines = SourceHead.lines
    /// What the name, the description, the rules and the path under them come to, near enough.
    /// Deliberately generous: it is better to show a line fewer than to lose the heading.
    private static let chrome: CGFloat = 150
    /// One line of `Typo.codeSmall`, rounded up. Read as a constant rather than resolved, because
    /// this only has to be close enough to choose how many lines fit.
    private static let lineHeight: CGFloat = 15
    /// Below this there is no glance left to offer, so the card keeps three lines and lets the
    /// window clip whatever it must.
    private static let minimumLines = 3

    @State private var documentation: SlashCommandIndex.Documentation?
    @State private var isLoaded = false

    var body: some View {
        MenuPanel {
            VStack(alignment: .leading, spacing: Metrics.spacing) {
                Text("/\(name)")
                    .font(Typo.code)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let detail = command?.detail, !detail.isEmpty {
                    // Capped, because a skill's description is routinely a paragraph of trigger
                    // phrases and the prose underneath is what the card came to show.
                    Text(detail)
                        .font(Typo.label)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let documentation, let shown = fitted(documentation) {
                    Hairline()
                    SourceLines(lines: shown.lines, truncated: shown.truncated)
                        .accessibilityHidden(true)
                } else if isLoaded, command?.path == nil {
                    Hairline()
                    Text(builtInNote)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: width, alignment: .leading)
            .padding(Metrics.inset)

            if let path = command?.path {
                Hairline()

                Text(shortened(path))
                    .font(Typo.codeSmall)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Metrics.inset)
                    .padding(.vertical, Metrics.spacing)
            }
        }
        .frame(maxWidth: width + Metrics.inset * 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: command?.path) { await load() }
    }

    /// The prose, cut to what the room above the composer can actually hold.
    ///
    /// The file was read at the file preview's own cap; this is only about how much of what was
    /// read fits on screen here. Anything dropped is said with the same ellipsis a truncated file
    /// gets, so a shortened card never claims to be the whole of the skill.
    private func fitted(_ documentation: SlashCommandIndex.Documentation) -> SlashCommandIndex.Documentation? {
        let budget = Int(((availableHeight - Self.chrome) / Self.lineHeight).rounded(.down))
        let allowed = max(Self.minimumLines, budget)
        guard documentation.lines.count > allowed else { return documentation }
        return SlashCommandIndex.Documentation(
            lines: Array(documentation.lines.prefix(allowed)),
            truncated: true
        )
    }

    private var builtInNote: String {
        command == nil
            ? "Bloom does not know this command. It will be sent as it is written."
            : "Built into the Claude Code CLI, so there is no file to open."
    }

    private var width: CGFloat {
        max(min(availableWidth - Metrics.gutter * 2, Self.maxWidth), 160)
    }

    /// The home directory written as `~`, because every one of these paths starts with it and the
    /// reader's own name is not the part that identifies the file.
    private func shortened(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// Read off the main actor, and only for a command that has a file. Keyed on the path, so
    /// moving the pointer from one chip to the next re-reads and moving it back does not.
    private func load() async {
        documentation = nil
        isLoaded = false
        guard let path = command?.path else {
            isLoaded = true
            return
        }
        // Read off the main actor, so the limits have to be captured here: a `View` is main actor
        // isolated and so are its own statics.
        let limit = Self.lines
        let columns = SourceHead.columns
        let found = await Task.detached(priority: .userInitiated) {
            SlashCommandIndex.documentation(of: path, lines: limit, columns: columns)
        }.value
        guard !Task.isCancelled else { return }
        documentation = found
        isLoaded = true
    }
}
