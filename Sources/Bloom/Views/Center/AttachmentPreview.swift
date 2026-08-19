import SwiftUI
import AppKit
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
        case unavailable
        case missing
    }

    @State private var phase: Phase = .loading

    /// The box the "no preview" and "it is gone" states are drawn in, so a card holding one of
    /// them is not a sliver.
    private static let minSide: CGFloat = 120

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
                    .font(.system(size: 28))
                    .foregroundStyle(Palette.textTertiary)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 48, height: 48)
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
