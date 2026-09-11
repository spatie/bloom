import SwiftUI
import AppKit
import UniformTypeIdentifiers
import BloomCore

/// The line that opens a turn the CLI started by itself, because a background task finished.
///
/// It stands where a prompt would, drawn in the shape of `SessionStartRowView`: a glyph, a label
/// and chips. Whether the row exists, what it says and why it never folds are all decided in the
/// core; see `BackgroundWake`.
struct BackgroundWakeRowView: View {
    var wake: BackgroundWake

    /// Asked once per row rather than in `body`. The CLI writes the output into its temporary
    /// directory, which does not outlive the machine's next clean up, so a transcript from last
    /// week names a file that is gone, and a link that does nothing is worse than no link.
    @State private var outputExists = false

    var body: some View {
        HStack(spacing: TranscriptLayout.glyphGap) {
            TranscriptGlyph(symbol: glyph, tint: glyphTint)

            Text(wake.title)
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize()

            if let name = wake.name {
                Chip(text: name)
            } else if !wake.summary.isEmpty {
                Text(wake.summary)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if let exit = wake.exitLabel {
                Chip(text: exit, tint: exitTint, monospaced: true)
                    .fixedSize()
            }

            Spacer(minLength: 0)

            if outputExists, let file = wake.outputFile {
                Button("Show output") { Self.open(file) }
                    .buttonStyle(.link)
                    .font(Typo.caption)
                    .help(file)
                    .fixedSize()
            }
        }
        .transcriptRowFrame()
        .accessibilityElement(children: .combine)
        .task(id: wake.outputFile) {
            outputExists = wake.outputFile.map { FileManager.default.fileExists(atPath: $0) } ?? false
        }
    }

    private var glyph: String {
        wake.source == .command ? "terminal" : "person.2"
    }

    private var glyphTint: Color {
        wake.outcome == .failed ? Palette.negative : Palette.textTertiary
    }

    private var exitTint: Color {
        switch wake.outcome {
        case .finished: Palette.positive
        case .failed: Palette.negative
        case .stopped: Palette.textSecondary
        }
    }

    /// In the Mac's text editor rather than a pane of Bloom's. The file sits in the CLI's temporary
    /// directory, outside the worktree, and `LocalPage` refuses anything outside it for reasons
    /// that must not be widened for this. `.output` has no type of its own either, so asking for
    /// the default application would put up a chooser instead of the text.
    private static func open(_ path: String) {
        let url = URL(filePath: path)
        guard let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText) else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }
}
