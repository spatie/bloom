import SwiftUI
import AppKit
import BloomCore

/// The `/command` the draft leads with, drawn as a chip above the text.
///
/// A sibling of `AttachmentChip` and deliberately built to the same measurements: the same height,
/// the same plate, the same icon slot that swaps for the close control under the pointer so the
/// chip keeps the width it had, and the same hover delay before a card opens. The two sit in the
/// same strip above the same box and they are the same kind of object, which is a thing the draft
/// carries that is not a word of the prompt.
///
/// What it is not is a second copy of an attachment. An attachment is a file the reader chose; this
/// is a token of the prompt itself, and the text under the chip is still the literal `/name` the
/// CLI is going to read. See `SlashCommandDraft`.
struct SlashCommandChip: View {
    /// The name as the draft spells it, which is the one thing that is always known.
    var name: String
    /// What the catalogue knows about that name, if it knows it at all. Nil for a command that is
    /// not installed here, which is a draft restored from somewhere else or a typo the reader has
    /// not noticed yet. The chip still draws, because the text still says what it says.
    var command: SlashCommand?
    var onRemove: @MainActor () -> Void
    /// Raised once the pointer has settled, and lowered the moment it leaves.
    var onHover: @MainActor (Bool) -> Void

    @State private var isHovered = false
    @State private var hoverTask: Task<Void, Never>?

    @Environment(\.openInRepoID) private var repoID

    /// The same slot as `AttachmentChip`, so a row holding one of each does not have two rhythms
    /// in it. Its constant rather than a copy of its value, for the reason `hoverDelay` below
    /// gives about the wait.
    private static let slot: CGFloat = AttachmentChip.slot
    /// And the same wait, which is `Motion.hoverCardDelay` rather than a number copied from that
    /// chip. It was copied, and then the shared constant moved and this one did not, which is the
    /// drift a promise in a comment cannot stop and a reference to the constant can.
    private static var hoverDelay: Duration { Motion.hoverCardDelay }
    /// Wide enough that a plugin's longest name is not truncated at all, which matters more here
    /// than it does on a filename: a middle truncated `superpowers:requesting-code-review` has
    /// lost the half that says which review it is.
    static let maxNameWidth: CGFloat = 340

    var body: some View {
        HStack(spacing: Metrics.spacingSmall) {
            leading

            Text("/\(name)")
                .font(Typo.codeSmall)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: Self.maxNameWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            trailing
        }
        .padding(.horizontal, Metrics.spacing)
        .frame(height: AttachmentChip.height)
        // Hugs its name rather than reserving the cap. The cap is a limit on a long name, not a
        // width for every chip, and a chip padded out to it reads as an empty field.
        .fixedSize(horizontal: true, vertical: false)
        .background {
            RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                .fill(isHovered ? Palette.hover : Palette.surfaceRaised)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                .strokeBorder(Palette.border, lineWidth: Metrics.outline)
        }
        .contentShape(RoundedRectangle(cornerRadius: Metrics.cornerSmall))
        .onHover(perform: hover(_:))
        .help(helpText)
        .contextMenu { menu }
        // One element rather than a container of three, so a screen reader hears the command and
        // what it does in one breath instead of stepping through two anonymous buttons to find out
        // what the chip is. Both of those buttons come back as named actions below.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Command /\(name)")
        .accessibilityValue(command?.detail ?? "")
        .accessibilityAddTraits(.isStaticText)
        .accessibilityAction(named: "Remove", onRemove)
        .accessibilityActions {
            if path != nil {
                Button("Open", action: open)
                Button("Reveal in Finder") { Reveal.inFinder(path ?? "") }
            }
        }
        .onDisappear { hoverTask?.cancel() }
    }

    // MARK: - Ends

    /// The command's mark, which becomes the close control under the pointer. A real button, so
    /// Tab reaches it and Space presses it without a mouse ever being involved.
    @ViewBuilder
    private var leading: some View {
        if isHovered {
            // The shared control rather than an `xmark.circle.fill` of its own, which cut its X
            // out of the disc so the X was the chip showing through. See `ChipRemoveMark`: this
            // chip is a sibling of `AttachmentChip` by design and was still missed by its fix.
            ChipRemoveButton(diameter: Self.slot, label: "Remove /\(name)", action: onRemove)
        } else {
            Image(systemName: glyph)
                .resizable()
                .scaledToFit()
                .frame(width: Self.slot, height: Self.slot)
                .foregroundStyle(Palette.textSecondary)
                .accessibilityHidden(true)
        }
    }

    /// The way into the file, on a chip that has one.
    ///
    /// A built in has nothing behind it: `/compact` and `/review` are compiled into the CLI, so
    /// there is no file to open and the control is absent rather than present and inert. The slot
    /// is still held open, for the same reason the leading one is fixed: a chip that changed width
    /// under the pointer would move the thing beside it out from under the pointer.
    @ViewBuilder
    private var trailing: some View {
        if path != nil {
            Button(action: open) {
                Image(systemName: "arrow.up.forward.square")
                    .resizable()
                .scaledToFit()
                    .frame(width: Self.slot, height: Self.slot)
                    .foregroundStyle(isHovered ? Palette.textSecondary : .clear)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(openTitle)
            .accessibilityLabel(openTitle)
        }
    }

    @ViewBuilder
    private var menu: some View {
        if let path {
            OpenInItems(target: .file(path), noun: "Skill")
            Divider()
            Button("Reveal in Finder") { Reveal.inFinder(path) }
        }
        Divider()
        Button("Remove /\(name)", action: onRemove)
    }

    // MARK: - Facts

    private var path: String? { command?.path }

    /// A skill and a command file are told apart, because "open" means a different kind of thing
    /// for each, and a built in gets the mark of something that lives in the CLI rather than a
    /// page it does not have.
    private var glyph: String {
        guard let command else { return "questionmark.circle" }
        return switch command.kind {
        case .skill: "sparkles"
        case .command: command.path == nil ? "terminal" : "text.page"
        }
    }

    private var openTitle: String {
        guard let app = path.flatMap({ OpenIn.preferred(for: .file($0), repo: repoID) }) else {
            return "Open /\(name)"
        }
        return "Open in \(app.app.name)"
    }

    private var helpText: String {
        let detail = command?.detail ?? ""
        return detail.isEmpty ? "/\(name)" : "/\(name)  \(detail)"
    }

    /// The application the rest of the app would use, which is what "open it up" has to mean here:
    /// the file is in `~/.claude`, outside the worktree, so the review tab cannot show it and the
    /// editor the reader already opens everything else in is the honest answer.
    private func open() {
        guard let path else { return }
        // One call: `Reveal.inEditor` asks `OpenIn.preferred` itself now, and records the choice.
        Reveal.inEditor(path, repo: repoID)
    }

    private func hover(_ hovering: Bool) {
        isHovered = hovering
        hoverTask?.cancel()

        guard hovering else {
            onHover(false)
            return
        }
        hoverTask = Task {
            try? await Task.sleep(for: Self.hoverDelay)
            guard !Task.isCancelled else { return }
            onHover(true)
        }
    }
}
