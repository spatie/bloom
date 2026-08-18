import SwiftUI
import BatonCore

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
        Group {
            if isLoading {
                LoadingView("Reading the file")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if lines.isEmpty {
                EmptyStateView(
                    glyph: "doc",
                    title: "Nothing to show",
                    message: "\((path as NSString).lastPathComponent) is empty, or is not text."
                )
            } else {
                content
            }
        }
        .background(Palette.surface)
        .task(id: LoadID(workspaceID: model.workspace.id, path: path)) { await load() }
    }

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
                        Text("Showing the first \(Self.lineLimit) lines")
                            .font(Typo.micro)
                            .foregroundStyle(Palette.textTertiary)
                            .padding(InspectorLayout.inset)
                    }
                }
                .frame(width: width, alignment: .leading)
            }
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
