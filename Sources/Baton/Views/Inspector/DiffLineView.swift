import SwiftUI
import BatonCore

/// One rendered diff line: gutter numbers, the marker column, and the highlighted source.
///
/// The same view serves both layouts. Unified asks for both number columns, side by side asks for
/// one and is given an explicit width so the two panes stay aligned even when a line is empty.
struct DiffLineView: View {
    /// Which gutters this row shows. Side by side shows one, unified shows both.
    enum Numbers {
        case both
        case old
        case new
        case none
    }

    var line: DiffLine?
    var language: Language
    var carry: LexState = LexState()
    var emphasis: [Range<String.Index>] = []
    var numbers: Numbers = .both
    /// Total width of the row, including gutters. Fixed by the file's widest line so every row
    /// scrolls horizontally as one sheet rather than each row scrolling on its own.
    var width: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            gutter
            content
        }
        .frame(width: width, height: CodeMetrics.rowHeight, alignment: .leading)
    }

    // MARK: - Gutter

    @ViewBuilder
    private var gutter: some View {
        HStack(spacing: 0) {
            switch numbers {
            case .both:
                number(line?.oldNumber)
                number(line?.newNumber)
            case .old:
                number(line?.oldNumber)
            case .new:
                number(line?.newNumber)
            case .none:
                EmptyView()
            }
        }
        .background(Palette.diffGutter)
    }

    /// Right aligned, dimmed and monospaced, so a column of numbers reads as a ruler rather than
    /// as content competing with the code beside it.
    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .font(Typo.codeTiny)
            .monospacedDigit()
            .foregroundStyle(Palette.textTertiary)
            .frame(width: CodeMetrics.numberWidth, alignment: .trailing)
            .padding(.trailing, CodeMetrics.gutterPadding)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let line {
            switch line.kind {
            case .noNewline:
                HStack(spacing: 0) {
                    marker
                    Text("No newline at end of file")
                        .font(Typo.codeTiny)
                        .foregroundStyle(Palette.textTertiary)
                        .italic()
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            default:
                // The word level emphasis is a background on the glyph runs inside `CodeText`, so
                // it paints over the row tint underneath rather than replacing it. Both are needed:
                // the tint says the line changed, the emphasis says which part of it did.
                HStack(spacing: 0) {
                    marker
                    CodeText(line: line.text, language: language, carry: carry)
                        .emphasizing(emphasis, color: emphasisColor)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(background)
            }
        } else {
            // Padding opposite a longer run on the other side. Sunken rather than empty, so the
            // eye reads it as "nothing here" instead of "unchanged".
            Rectangle()
                .fill(Palette.surfaceSunken)
                .frame(maxWidth: .infinity)
        }
    }

    private var marker: some View {
        Text(markerText)
            .font(Typo.codeTiny)
            .foregroundStyle(Palette.textTertiary)
            .frame(width: CodeMetrics.markerWidth, alignment: .center)
    }

    private var markerText: String {
        switch line?.kind {
        case .addition: "+"
        case .deletion: "-"
        case .noNewline: "\\"
        default: " "
        }
    }

    private var background: Color {
        switch line?.kind {
        case .addition: Palette.diffAddBackground
        case .deletion: Palette.diffDeleteBackground
        default: .clear
        }
    }

    private var emphasisColor: Color {
        switch line?.kind {
        case .addition: Palette.diffAddEmphasis
        case .deletion: Palette.diffDeleteEmphasis
        default: .clear
        }
    }
}

/// The `@@` line, showing the enclosing function git found. Quiet, because it is orientation
/// rather than content.
struct DiffHunkHeaderView: View {
    var text: String
    var width: CGFloat

    var body: some View {
        HStack(spacing: InspectorLayout.gap) {
            Image(systemName: "arrow.left.and.right")
                .font(Typo.micro)
                .imageScale(.small)
            Text(text)
                .font(Typo.codeTiny)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Palette.textTertiary)
        .padding(.horizontal, CodeMetrics.textInset)
        .frame(width: width, height: CodeMetrics.rowHeight, alignment: .leading)
        .background(Palette.surfaceSunken)
    }
}

/// The affordance that reveals context a diff hid.
struct DiffExpanderView: View {
    var title: String
    var width: CGFloat
    var action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: InspectorLayout.gap) {
                Image(systemName: "chevron.up.chevron.down")
                    .font(Typo.micro)
                    .imageScale(.small)
                Text(title)
                    .font(Typo.codeTiny)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isHovered ? Palette.accent : Palette.textTertiary)
            .padding(.horizontal, CodeMetrics.textInset)
            .frame(width: width, height: CodeMetrics.rowHeight, alignment: .leading)
            .background(isHovered ? Palette.hover : Palette.surfaceSunken)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
