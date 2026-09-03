import SwiftUI
import UniformTypeIdentifiers
import BloomCore

/// A file the centre column cannot show as lines of text: an image, a PDF, a video, an archive.
///
/// It exists because `FilePreview` answers a different question. That one reads a file as UTF-8
/// and sets it in the code font with line numbers down the side, which is right for source and
/// says "Nothing to show" for a screenshot. An attachment is very often a screenshot, and clicking
/// its chip has to land on the picture.
///
/// The bar over the top is the one `FilePreview` draws, said the same way: the path relative to
/// the worktree root, quiet, then the name in bold. The reveal button is Finder rather than an
/// editor, because opening a JPEG in a text editor is not a thing anybody wants.
struct FileMediaView: View {
    var worktree: String
    /// Relative to the worktree, exactly as the review tab carries it.
    var path: String

    /// The bar's own width, for the same reason `FilePreview` measures its own. This bar used to
    /// measure nothing and always draw the folder, so the one of the three that is most often
    /// opened in a narrow pane was also the one that could not give the folder up.
    @State private var width: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()

            GeometryReader { proxy in
                AttachmentPreview(
                    url: url,
                    maxWidth: max(proxy.size.width - Metrics.pane * 2, 1),
                    maxHeight: max(proxy.size.height - Metrics.pane * 2, 1)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Palette.surface)
    }

    private var header: some View {
        HStack(spacing: InspectorLayout.gap) {
            FilePathLabel(path: path, width: width)

            Spacer(minLength: InspectorLayout.tight)

            Button("Reveal in Finder", systemImage: "folder") {
                Reveal.inFinder(url.path)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Show \(filename) in Finder")
        }
        .padding(.horizontal, InspectorLayout.inset)
        .frame(height: InspectorLayout.barHeight)
        .background(Palette.surfaceSunken)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .help(path)
    }

    private var url: URL {
        URL(filePath: (worktree as NSString).appendingPathComponent(path))
    }

    private var filename: String { (path as NSString).lastPathComponent }

    /// Whether a path is one of these rather than one for `FilePreview`.
    ///
    /// Asked of the extension rather than of the bytes, so nothing is read twice to find out. A
    /// type nobody recognises stays with `FilePreview`, which reads it and says plainly that it is
    /// not text when it cannot. Text and source code are named first because several of them, an
    /// SVG most of all, conform to a binary type as well.
    static func isMedia(path: String) -> Bool {
        guard let type = UTType(filenameExtension: (path as NSString).pathExtension) else {
            return false
        }
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) { return false }
        return [UTType.image, .pdf, .audiovisualContent, .archive, .font]
            .contains { type.conforms(to: $0) }
    }
}
