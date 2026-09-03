import SwiftUI
import AppKit
import BloomCore
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// What a file looks like, at whatever size the caller has room for.
///
/// One implementation for the card that floats over the composer and for the centre tab, because
/// they are the same question asked twice and two answers would drift.
///
/// Quick Look does the drawing. There is no reasonable way for Bloom to render a HEIC, the first
/// page of a PDF, a frame of a video and the head of a text file, and macOS has been doing all
/// four for fifteen years. The thumbnail is asked for at the size it will be drawn at rather than
/// scaled up from an icon, so a photo in the tab is as sharp as the display allows.
///
/// `representationTypes` is deliberately `.thumbnail` alone. With `.all`, Quick Look answers for
/// everything by falling back to the document icon, and a hover card showing a 400 point generic
/// binary icon claims to be a preview while telling the reader nothing. Asking only for the real
/// thing means a type nobody can preview fails, and failing is what lets this say so out loud.
struct AttachmentPreview: View {
    var url: URL
    var maxWidth: CGFloat
    var maxHeight: CGFloat

    private enum Phase {
        case loading
        /// The bitmap Quick Look drew, and the scale it drew it at. Both, because the bitmap is in
        /// pixels: at 2x a 520 point thumbnail comes back 1040 wide, and drawing that as points
        /// puts a card twice the width of the window over the composer.
        case ready(CGImage, scale: CGFloat)
        /// The head of a text file, already trimmed to what will fit, and whether there was more.
        case text([String], truncated: Bool)
        case unavailable
        case missing
    }

    @State private var phase: Phase = .loading

    /// The box the "no preview" and "it is gone" states are drawn in, so a card holding one of
    /// them is not a sliver.
    private static let minSide: CGFloat = 120

    /// The mark at the head of one of those two cards, and the box a file's own icon is drawn in.
    ///
    /// Deliberately off `Typo` and off `Metrics`, and said here rather than left as two bare
    /// numbers in the stack below. `Typo` stops at 15, which is a heading inside prose, and its own
    /// doc argues that a sixth rung invented for one card is how a five rung scale stops being one;
    /// this is a picture rather than type. `NSWorkspace` hands an icon back at 16, 32 and 128, and
    /// 48 is the step between the middle two that keeps it sharp beside `minSide`. The two are a
    /// pair: the drawn glyph is smaller than the file icon because a stroked symbol at the icon's
    /// size outweighs the filename under it.
    private static let noteGlyph: CGFloat = 28
    private static let noteIcon: CGFloat = 48

    var body: some View {
        content
            .frame(maxWidth: maxWidth, maxHeight: maxHeight)
            .task(id: LoadID(path: url.path, width: maxWidth, height: maxHeight)) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(width: Self.minSide, height: Self.minSide)
        case .ready(let image, let scale):
            // Sized by its scale rather than made resizable. Quick Look was asked for the
            // thumbnail at the size it is being drawn at, so it already fits, and an image with a
            // definite size of its own is what lets the card be laid out above the composer: a
            // resizable one has no height until something proposes one, and the only height on
            // offer up there is the composer's own.
            Image(image, scale: scale, label: Text("Preview of \(url.lastPathComponent)"))
        case .text(let lines, let truncated):
            SourceLines(lines: lines, truncated: truncated)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("The first lines of \(url.lastPathComponent)")
        case .unavailable:
            unpreviewable
        case .missing:
            note(
                glyph: "doc.questionmark",
                title: "\(url.lastPathComponent) is gone",
                detail: "It is no longer on disk."
            )
        }
    }

    /// A file Quick Look cannot draw. The file's own icon, its kind and its size: everything that
    /// is true about it, said plainly, rather than an empty rectangle that reads as a failure to
    /// load.
    private var unpreviewable: some View {
        note(
            glyph: nil,
            title: url.lastPathComponent,
            detail: [kindDescription, sizeDescription].compactMap { $0 }.joined(separator: " · ")
        )
    }

    private func note(glyph: String?, title: String, detail: String) -> some View {
        VStack(spacing: Metrics.spacing) {
            if let glyph {
                Image(systemName: glyph)
                    .font(.system(size: Self.noteGlyph))
                    .foregroundStyle(Palette.textTertiary)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: Self.noteIcon, height: Self.noteIcon)
            }

            Text(title)
                .font(Typo.bodyEmphasis)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            if !detail.isEmpty {
                Text(detail)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(Metrics.pane)
        .frame(minWidth: Self.minSide * 2, minHeight: Self.minSide)
    }

    private var kindDescription: String? {
        UTType(filenameExtension: url.pathExtension)?.localizedDescription
    }

    private var sizeDescription: String? {
        let bytes = AttachmentFiles.byteCount(of: url.path)
        guard bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Reloading is keyed on the size as well as the path, so the card and the tab do not share a
    /// thumbnail generated for the smaller of the two.
    private struct LoadID: Hashable {
        var path: String
        var width: CGFloat
        var height: CGFloat
    }

    private func load() async {
        guard FileManager.default.fileExists(atPath: url.path) else {
            phase = .missing
            return
        }

        // Text before Quick Look, because for text Quick Look is the wrong answer. See `source`.
        if !FileMediaView.isMedia(path: url.path),
           AttachmentFiles.byteCount(of: url.path) <= SourceHead.byteLimit {
            let path = url.path
            let head = await Task.detached(priority: .utility) { SourceHead.read(path) }.value
            guard !Task.isCancelled else { return }
            if let head, !head.lines.isEmpty {
                phase = .text(head.lines, truncated: head.truncated)
                return
            }
        }

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: max(maxWidth, Self.minSide), height: max(maxHeight, Self.minSide)),
            scale: scale,
            representationTypes: .thumbnail
        )

        do {
            let representation = try await QLThumbnailGenerator.shared
                .generateBestRepresentation(for: request)
            guard !Task.isCancelled else { return }
            phase = .ready(representation.cgImage, scale: scale)
        } catch {
            guard !Task.isCancelled else { return }
            phase = .unavailable
        }
    }
}

/// The head of a source file, set the way the transcript sets code.
///
/// Quick Look can draw a text file and the answer was never worth having: it renders the content
/// onto a page, and a page is a portrait rectangle whatever is on it, so a seventeen line file came
/// back as a 422 by 445 thumbnail with the text in the top third and two hundred and fifty points
/// of white underneath. The card was that shape because the bitmap was. Real text has the height of
/// the text in it, which is the whole of what "size to content" means here, and it is drawn as
/// glyphs rather than as a picture of glyphs, so it is sharp at any scale and legible at this size,
/// which the thumbnail was not.
///
/// Leading aligned and not wrapped: code that soft wraps in a hover card reads as different code. A
/// long line is cut and says so with the same ellipsis a truncated file gets.
///
/// Its own view because two cards want it. The file preview draws the head of whatever was
/// attached; the slash command card draws the head of a skill with its frontmatter taken off. Both
/// are "some lines of a text file, sized to what is in them", and a second copy of this is how the
/// two would stop looking alike.
struct SourceLines: View {
    var lines: [String]
    var truncated: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // One `Text` a line rather than one `Text` with newlines in it. A single run wraps,
            // and a wrapped line of code is a line of code that is not there; per line, each one
            // truncates at the card's own width instead, which is also what makes the block as
            // wide as its widest line and no wider.
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if truncated {
                Text("\u{2026}")
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .font(Typo.codeSmall)
        .foregroundStyle(Palette.textPrimary)
        .textSelection(.disabled)
    }
}

/// Reading the head of a text file, off the main actor.
///
/// Its own type rather than a method on the view, because a `View` is main actor isolated and so
/// are its statics, and this runs on a detached task: the limits below would be main actor state
/// read from a background thread.
enum SourceHead {
    /// Past this, a file is an attachment rather than something to print. Half a megabyte of one
    /// line JSON has nothing to show and reading it is not free.
    static let byteLimit = 512 * 1024

    /// The first lines of a file, or nil for anything that is not UTF-8 after all.
    ///
    /// How many lines that is, and how long one may be, is `TextHead` in the core: the card over a
    /// chip that stands for words rather than for a file cuts them with the same two numbers, and
    /// the two cards sit in the same popover.
    static func read(_ path: String) -> (lines: [String], truncated: Bool)? {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return TextHead.head(of: text)
    }
}
