import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// One attached file: the icon Finder would draw for it, then its name.
///
/// Drawn twice, above what you are typing and again in the turn once it has been sent, and it is
/// deliberately one view. The chips in a sent prompt are the same files the reader chose a moment
/// earlier, and a second implementation of the same label is how the two stop looking alike.
///
/// The name only. A path in a chip is a path in the composer again, which is the thing this
/// replaces, and the folder an attachment came from is never the interesting part: the reader
/// dropped it a second ago and the hover card and the tab both say where it went.
///
/// Drawn on two very different grounds. Above the text field it sits on the composer's sunken
/// grey; inside a sent turn it sits on the filled blue bubble `UserTurnRowView` draws. The second
/// case is read from `isOnEmphasizedSelection`, the same environment value a selected sidebar row
/// sets, so the chip needs to know nothing about either caller: on the fill it becomes a light
/// plate with light ink, exactly as `Chip` and `DiffStatLabel` already do on the same colour. A
/// chip that kept its raised white plate and its primary ink would be the one thing in the bubble
/// still coloured for a white page, and it is the piece a reader looks straight at.
///
/// Drawn in a transcript's tool rows as well, which is where the cost of anything it does per
/// chip stops being theoretical: a turn is hundreds of rows in a lazy list, and every one of them
/// that names a file draws one of these. So the icon comes from `FileTypeIcon`, which answers per
/// file *type* rather than per file and never touches the disk, and the probe that marks a missing
/// file is behind `verifiesOnDisk` and is off for those rows. See both for why.
///
/// Hovering swaps the icon for the close control rather than adding one beside it, which is what
/// Conductor does and is worth copying: the chip keeps exactly the width it had, so a row of them
/// does not reflow under the pointer and the thing you were aiming at stays where it was. The slot
/// is a fixed square for that reason, not because the two glyphs happen to be the same size.
struct AttachmentChip: View {
    var attachment: PromptAttachment
    var worktree: String
    /// Nil where the chip has nowhere to go, which is a file outside the worktree: the review
    /// resolves a path against the worktree and cannot show one from another checkout. The chip is
    /// still drawn, because it is still a file and the icon is still the honest thing to say about
    /// it. It simply does not answer to the pointer.
    var onOpen: (@MainActor () -> Void)?
    /// Nil where there is nothing to take the chip off, which is a turn that has already been
    /// sent: the prompt the agent read named that file, so the transcript cannot un-name it. The
    /// icon then stays an icon rather than swapping under the pointer.
    var onRemove: (@MainActor () -> Void)?
    /// Raised once the pointer has settled, and lowered the moment it leaves. Nil where nobody is
    /// listening, which costs the chip its hover timer rather than running one for no reader.
    var onHover: (@MainActor (Bool) -> Void)?
    /// Where this chip is in the window, reported on the same timer `onHover` uses, and nil again
    /// when the pointer leaves.
    ///
    /// The transcript's answer to "show me the file". Its chips live inside a `LazyVStack` in a
    /// `ScrollView`, where a card drawn beside the chip is clipped by the pane, so the card is
    /// drawn over the scroll view instead and has to be told where the chip it belongs to is. In
    /// window coordinates rather than a named space, so the chip needs to know nothing about which
    /// view is going to draw the card.
    ///
    /// Nil in the composer, which has its own card and positions it by an alignment guide.
    var onPreview: (@MainActor (CGRect?) -> Void)?
    /// Whether to ask the file system if this file is still there, which paints the warning
    /// triangle when it is not.
    ///
    /// True in the composer alone, where the reader picked that file a moment ago, has not sent
    /// anything yet, and a copy that has gone missing under `.bloom/attachments` is news they can
    /// still act on.
    ///
    /// False everywhere in a transcript, tool rows and sent prompts alike, for two reasons and the
    /// second is the real one: a stat per row on the main actor is a stat per row scrolled past,
    /// and the answer would be wrong anyway. A file the agent wrote at step three and deleted at
    /// step nine was a file when the row was written, and the row is a record of what happened
    /// rather than a picker. The same goes for a prompt: every path in a sent one was a readable
    /// file at the moment it was sent, and a triangle appearing on it hours later says the turn
    /// was broken when what actually happened is that the worktree moved on.
    var verifiesOnDisk = true

    @State private var isHovered = false
    @State private var isMissing = false
    @State private var hoverTask: Task<Void, Never>?
    /// Read once, when the pointer enters, and only where a preview is wanted. See `probe`.
    @State private var frameInWindow: CGRect = .zero

    /// True inside a sent user turn, where the ground is the accent fill rather than the page.
    @Environment(\.isOnEmphasizedSelection) private var isOnSelection

    /// Shorter than a list row: this is a label above the text field, and at 28 points a row of
    /// them read as a second toolbar. Not private: the bar reads it to know how tall one row of
    /// chips is before it has measured any.
    ///
    /// It is `Metrics.controlHeight` rather than a 22 of its own, which is what it was: the same
    /// number, said twice. That rung is "a control drawn with a fill of its own inside a strip",
    /// which is exactly what a chip is.
    static let height: CGFloat = Metrics.controlHeight
    /// The icon, and the close control that replaces it.
    ///
    /// Not private, because `SlashCommandChip` and `ReviewCommentChip` each held a 14 of their own
    /// with a comment promising it was this one. `SlashCommandChip` already condemns that shape
    /// three lines below its copy, for `hoverDelay`: a promise in a comment cannot stop the drift
    /// and a reference to the constant can.
    static let slot: CGFloat = 14
    /// Enough for a name like `Screenshot 2026-08-19 at 14.03.11.png` to be recognisable once it
    /// is truncated in the middle, and short enough that four chips fit across a narrow column.
    private static let maxNameWidth: CGFloat = 150
    /// How long the pointer has to rest before the card opens. Short enough to feel like hovering,
    /// long enough that crossing the row on the way to the send button shows nothing. Shared with
    /// the sidebar's card, the composer's and the transcript's, so the whole window answers a
    /// resting pointer at one speed.
    private static var hoverDelay: Duration { Motion.hoverCardDelay }

    var body: some View {
        HStack(spacing: Metrics.spacingSmall) {
            leading

            Text(attachment.filename)
                .font(Typo.caption)
                .foregroundStyle(nameColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: Self.maxNameWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            if isMissing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .imageScale(.small)
                    // Amber is a warning colour picked to be seen on the page's ground, and on the
                    // blue fill it is the one saturated mark in the turn. The chip is already
                    // saying "missing" in the shape of the glyph, so on the fill it says it in the
                    // fill's own ink instead.
                    .foregroundStyle(isOnSelection ? Palette.selectedEmphasizedText : Palette.warning)
                    .help("This file is no longer on disk")
                    // `.help` is a tooltip and reaches nobody who is not pointing at it. The chip
                    // is labelled with the filename alone, so without this a file that is not
                    // there sounds exactly like one that is, on the send path.
                    .accessibilityLabel("Missing")
            }
        }
        .padding(.horizontal, Metrics.spacing)
        .frame(height: Self.height)
        .background {
            RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                .fill(plate)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                .strokeBorder(stroke, lineWidth: Metrics.outline)
        }
        .background { probe }
        .contentShape(RoundedRectangle(cornerRadius: Metrics.cornerSmall))
        .modifier(TapWhenOffered(action: onOpen))
        .onHover(perform: hover(_:))
        .help(attachment.path)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(attachment.filename)
        .accessibilityHint(onOpen == nil ? "" : "Opens \(attachment.path) in a tab")
        .modifier(PresenceProbe(path: verifiesOnDisk ? url.path : nil, isMissing: $isMissing))
        .onDisappear { hoverTask?.cancel() }
    }

    // MARK: Ground

    /// The plate under the chip. On the accent fill it is the same twenty percent of the inverted
    /// ink `Chip` uses there, which reads as a lighter patch of the bubble rather than as a white
    /// card sitting on top of it. Hover lifts it by a further tenth.
    private var plate: Color {
        guard isOnSelection else {
            return isHovered ? Palette.hover : Palette.surfaceRaised
        }
        return Palette.selectedEmphasizedText.opacity(isHovered ? 0.3 : 0.2)
    }

    /// A hairline in the page's border colour disappears into the fill, so on the accent the edge
    /// is drawn in the same ink as the label, kept faint enough to stay an edge.
    private var stroke: Color {
        isOnSelection ? Palette.selectedEmphasizedText.opacity(0.35) : Palette.border
    }

    /// A file that is no longer on disk is said quietly rather than in a different hue, which is
    /// what `textTertiary` does on the page and what three quarters of the inverted ink does here.
    private var nameColor: Color {
        guard isOnSelection else {
            return isMissing ? Palette.textTertiary : Palette.textPrimary
        }
        return isMissing
            ? Palette.selectedEmphasizedText.opacity(0.75)
            : Palette.selectedEmphasizedText
    }

    @ViewBuilder
    private var leading: some View {
        if isHovered, let onRemove {
            // A drawn glyph on a plate rather than `xmark.circle.fill`, which is the fix this
            // chip got first and the other three did not, including the one inside the composer
            // box that the complaint had actually been about. `ChipRemoveMark` is where the
            // argument lives now, so the next chip cannot be written without it.
            ChipRemoveButton(
                diameter: Self.slot,
                label: "Remove \(attachment.filename)",
                action: onRemove
            )
        } else {
            Image(nsImage: FileTypeIcon.icon(for: attachment.filename))
                .resizable()
                .frame(width: Self.slot, height: Self.slot)
                .accessibilityHidden(true)
        }
    }

    private var url: URL { attachment.url(in: worktree) }

    /// Where the chip is, measured only while the pointer is on it.
    ///
    /// Reading a frame behind every chip in a transcript would be a read per chip per layout pass,
    /// on the list that re-lays out on every frame of a sidebar drag. Behind the hovered chip
    /// alone it is one chip's worth of reads, for the one chip that is about to be asked where it
    /// is, and nothing at all for the other four hundred.
    ///
    /// `onGeometryChange` rather than a `GeometryReader` with an `onAppear`: the frame is right
    /// even if the row is still settling when the pointer arrives, which `onAppear` cannot
    /// promise. It goes stale only if the content moves after the card is up, and moving the
    /// content is what dismisses the card.
    @ViewBuilder
    private var probe: some View {
        if onPreview != nil, isHovered {
            Color.clear
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    frameInWindow = $0
                }
        }
    }

    private func hover(_ hovering: Bool) {
        isHovered = hovering
        hoverTask?.cancel()

        guard onHover != nil || onPreview != nil else { return }
        guard hovering else {
            onHover?(false)
            onPreview?(nil)
            return
        }
        hoverTask = Task {
            try? await Task.sleep(for: Self.hoverDelay)
            guard !Task.isCancelled else { return }
            onHover?(true)
            // Zero only if the probe has not been laid out yet, which would place the card in the
            // pane's top left corner. Saying nothing is better than saying it in the wrong place.
            if frameInWindow != .zero { onPreview?(frameInWindow) }
        }
    }
}

/// The icon a file gets, worked out once per file type rather than once per file.
///
/// `NSWorkspace.icon(forFile:)` is the obvious call and it is the wrong one here. It reads the
/// file: it goes to disk for the custom icon a file may carry, and for something that is not there
/// it hands back a generic page. In a transcript that is one file system round trip per row per
/// appearance, on the main actor, in a list that is built and thrown away as it scrolls.
///
/// Asking about the *type* instead is a LaunchServices lookup with no path in it at all, and every
/// `.php` in the turn shares one answer, so the cache below is one entry per extension and the
/// hundredth Swift file costs a dictionary hit. What it gives up is the custom icon on an
/// individual file and the artwork of an app bundle, neither of which a chip fourteen points across
/// was ever going to show usefully.
@MainActor
enum FileTypeIcon {
    /// Keyed by lowercased extension. Small by construction: a repository has a handful of file
    /// types in it, and the empty key is the one every extensionless name shares.
    private static var cache: [String: NSImage] = [:]

    static func icon(for filename: String) -> NSImage {
        let ext = (filename as NSString).pathExtension.lowercased()
        if let cached = cache[ext] { return cached }

        // `.data` rather than `.item` for a name with no extension: a generic document, which is
        // what an extensionless file almost always is, rather than the blank sheet the system uses
        // for something it has no opinion about at all.
        let type = ext.isEmpty ? UTType.data : (UTType(filenameExtension: ext) ?? .data)
        let icon = NSWorkspace.shared.icon(for: type)
        cache[ext] = icon
        return icon
    }
}

/// A tap gesture, only where there is somewhere to tap to.
///
/// A gesture with an empty closure is not the same as no gesture: it swallows the click, which
/// inside a transcript row means the row stops expanding when you click its chip.
private struct TapWhenOffered: ViewModifier {
    var action: (@MainActor () -> Void)?

    func body(content: Content) -> some View {
        if let action {
            content.onTapGesture(perform: action)
        } else {
            content
        }
    }
}

/// Asks the file system whether the file is still there, where anybody wants to know.
///
/// A modifier rather than a `guard` inside the task, so a chip that does not want the answer never
/// starts a task at all. That is the whole point in a transcript: the rows scroll, and a task per
/// row per appearance is work whether or not its body returns immediately.
private struct PresenceProbe: ViewModifier {
    var path: String?
    @Binding var isMissing: Bool

    func body(content: Content) -> some View {
        if let path {
            content.task(id: path) {
                isMissing = !FileManager.default.fileExists(atPath: path)
            }
        } else {
            content
        }
    }
}
