import SwiftUI
import BloomCore

/// Read-only source for a file the agent did not touch, highlighted with the same primitives the
/// diff uses.
struct FilePreview: View {
    let model: WorkspaceModel
    let path: String

    /// Far more than fits on a screen, and enough that scrolling never reaches the truncation on
    /// any file a person would open on purpose.
    private static let lineLimit = 5_000
    /// A horizontal scroll wider than this helps nobody and makes the scroller useless.
    private static let columnLimit = 800
    /// The same cap `FilePathChip` puts on the folder above a diff.
    private static let chipWidth: CGFloat = 170

    @State private var lines: [String] = []
    @State private var carries: [LexState] = []
    @State private var language: Language = .plainText
    @State private var maxColumns = 0
    @State private var isTruncated = false
    @State private var isLoading = true

    private struct LoadID: Hashable {
        var workspaceID: String
        var path: String
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()

            Group {
                if isLoading {
                    LoadingView("Reading the file")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if lines.isEmpty {
                    EmptyStateView(
                        glyph: "doc",
                        title: "Nothing to show",
                        message: "\(filename) is empty, or is not text."
                    )
                } else {
                    content
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Palette.surface)
        .task(id: LoadID(workspaceID: model.workspace.id, path: path)) { await load() }
    }

    /// The same bar `DiffView` puts over a changed file, so clicking through the worktree tree
    /// does not land the reader in an unlabelled wall of code. It says less because there is less
    /// to say: nothing here can be edited, reverted or laid out two ways.
    private var header: some View {
        HStack(spacing: InspectorLayout.gap) {
            if !directory.isEmpty {
                Chip(text: directory)
                    .frame(maxWidth: Self.chipWidth, alignment: .leading)
                    .layoutPriority(-1)
            }

            Text(filename)
                .font(Typo.bodyEmphasis)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: InspectorLayout.tight)

            Button("Open in Editor", systemImage: "square.and.pencil") {
                Reveal.inEditor((model.workspace.path as NSString).appendingPathComponent(path))
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Open \(filename) in your editor")
        }
        .padding(.horizontal, InspectorLayout.inset)
        .frame(height: InspectorLayout.barHeight)
        .background(Palette.surfaceSunken)
        .help(path)
    }

    private var filename: String { (path as NSString).lastPathComponent }

    private var directory: String { (path as NSString).deletingLastPathComponent }

    /// `GeometryReader` because the sheet has to be at least as wide as the container AND at least
    /// as wide as the longest line, and there is no container-relative modifier that expresses a
    /// maximum of the two.
    private var content: some View {
        GeometryReader { proxy in
            let width = max(
                proxy.size.width,
                CGFloat(maxColumns) * CodeMetrics.advance
                    + CodeMetrics.numberWidth
                    + CodeMetrics.textInset
                    + CodeMetrics.gutterPadding * 2
            )
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines.indices, id: \.self) { index in
                        row(at: index, width: width)
                    }
                    if isTruncated {
                        Text("Showing the first \(Self.lineLimit.formatted()) lines")
                            .font(Typo.micro)
                            .foregroundStyle(Palette.textTertiary)
                            .padding(InspectorLayout.inset)
                    }
                }
                .frame(width: width, alignment: .leading)
            }
            // As in `DiffView`: two axes centre content that does not fill the pane.
            .defaultScrollAnchor(.topLeading)
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func row(at index: Int, width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text("\(index + 1)")
                .font(Typo.codeTiny)
                .monospacedDigit()
                .foregroundStyle(Palette.textTertiary)
                .frame(width: CodeMetrics.numberWidth, alignment: .trailing)
                .padding(.trailing, CodeMetrics.gutterPadding)
                .background(Palette.diffGutter)
            CodeText(
                line: lines[index],
                language: language,
                carry: index < carries.count ? carries[index] : LexState()
            )
            // The diff pays for this with its marker column. Without it here the first character
            // of every line sits against the gutter's edge, and the width computed above already
            // reserves the room.
            .padding(.leading, CodeMetrics.textInset)
            Spacer(minLength: 0)
        }
        .frame(width: width, height: CodeMetrics.rowHeight, alignment: .leading)
    }

    private func load() async {
        isLoading = true
        let source = model.contents(of: path)
        let detected = Language.detect(path: path)

        guard let source else {
            lines = []
            isLoading = false
            return
        }

        let all = source.components(separatedBy: "\n")
        let truncated = all.count > Self.lineLimit
        let kept = truncated ? Array(all.prefix(Self.lineLimit)) : all

        let states = await Task.detached(priority: .userInitiated) {
            CarryPass.states(for: kept, language: detected)
        }.value

        guard !Task.isCancelled else { return }
        lines = kept
        carries = states
        language = detected
        isTruncated = truncated
        maxColumns = min(kept.reduce(0) { max($0, CodeMetrics.columns(of: $1)) }, Self.columnLimit)
        isLoading = false
    }
}
