import SwiftUI
import AppKit
import BloomCore

/// Code gets a dedicated surface so syntax state can flow across lines without flattening the transcript.
public struct CodeBlockView: View {
    /// Beyond this the fence is folded, because a `Text` per line is not a pager.
    private static let lineCap = 2_000

    private let code: String
    private let language: Language
    private let showsLineNumbers: Bool
    @State private var copied = false
    @State private var copyReset: Task<Void, Never>?
    @State private var showsAllLines = false

    /// The gutter follows the conversation's text size, otherwise a raised size runs the numbers
    /// into the code beside them. This was a `@ScaledMetric`, which on macOS never moves: there is
    /// no Dynamic Type for it to track.
    @Environment(\.fontScale) private var fontScale
    /// Whether the answer this fence belongs to is still arriving, which decides which cache the
    /// preparation goes through. See `CodeBlockPreparationCache`.
    @Environment(\.markdownIsStreaming) private var isStreaming

    private var lineNumberWidth: CGFloat { MarkdownMetrics.lineNumberWidth * fontScale }

    public init(code: String, language: Language, showsLineNumbers: Bool = false) {
        self.code = code
        self.language = language
        self.showsLineNumbers = showsLineNumbers
    }

    public var body: some View {
        let prepared = CodeBlockPreparationCache.prepared(
            code: code, language: language, isStreaming: isStreaming
        )
        let visibleCount = showsAllLines ? prepared.lines.count : min(prepared.lines.count, Self.lineCap)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Metrics.spacing) {
                // The fence's only label, and the one thing that says what the block is. It was
                // at the floor of the scale, a rung under the smallest thing it names.
                Text(Self.displayName(for: language))
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                Spacer(minLength: MarkdownMetrics.blockGap)
                Button(action: copy) {
                    Label(copied ? "Copied" : "Copy code", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .labelStyle(.iconOnly)
                        .font(Typo.caption)
                        .imageScale(.medium)
                        .foregroundStyle(copied ? Palette.positive : Palette.textTertiary)
                        .frame(width: MarkdownMetrics.iconButton, height: MarkdownMetrics.iconButton)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(copied ? "Copied" : "Copy code")
            }
            .padding(.horizontal, MarkdownMetrics.blockGap)
            .padding(.vertical, Metrics.spacing)

            Hairline()

            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(0..<visibleCount, id: \.self) { offset in
                        HStack(alignment: .firstTextBaseline, spacing: MarkdownMetrics.blockGap) {
                            if showsLineNumbers {
                                Text(String(offset + 1))
                                    .font(Typo.codeSmall)
                                    .foregroundStyle(Palette.textTertiary)
                                    .monospacedDigit()
                                    .frame(minWidth: lineNumberWidth, alignment: .trailing)
                            }
                            Text(SyntaxCache.attributed(
                                line: prepared.lines[offset],
                                language: language,
                                carry: prepared.carries[offset]
                            ))
                                .font(Typo.code)
                                .foregroundStyle(Palette.textPrimary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(MarkdownMetrics.blockGap)
            }

            if prepared.lines.count > Self.lineCap, !showsAllLines {
                Hairline()
                Button("Show all \(prepared.lines.count) lines") {
                    showsAllLines = true
                }
                .linkButton()
                .font(Typo.caption)
                .padding(.horizontal, MarkdownMetrics.blockGap)
                .padding(.vertical, Metrics.spacing)
            }
        }
        .background(Palette.surfaceSunken)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.corner))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.corner)
                .strokeBorder(Palette.border, lineWidth: Metrics.hairline)
        }
    }

    private func copy() {
        Clipboard.copy(code)
        copied = true
        // Cancelled and restarted, so a second copy inside the window does not have the first
        // one's timer clear the label out from under it a moment later.
        copyReset?.cancel()
        copyReset = Task {
            try? await Task.sleep(for: Clipboard.flashDuration)
            guard !Task.isCancelled else { return }
            copied = false
        }
    }

    private static func displayName(for language: Language) -> String {
        switch language {
        case .plainText: "Plain text"
        case .javascript: "JavaScript"
        case .typescript: "TypeScript"
        case .html: "HTML"
        case .css: "CSS"
        case .json: "JSON"
        case .yaml: "YAML"
        case .toml: "TOML"
        case .sql: "SQL"
        case .xml: "XML"
        case .php: "PHP"
        default: language.rawValue.capitalized
        }
    }
}

private final class CodeBlockPreparationKey: NSObject {
    let code: String
    let language: Language
    private let cachedHash: Int

    init(code: String, language: Language) {
        self.code = code
        self.language = language
        var hasher = Hasher()
        hasher.combine(code)
        hasher.combine(language)
        cachedHash = hasher.finalize()
    }

    override var hash: Int { cachedHash }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? CodeBlockPreparationKey else { return false }
        return cachedHash == other.cachedHash
            && code == other.code
            && language == other.language
    }
}

private final class CodeBlockPreparation {
    let lines: [String]
    let carries: [LexState]

    init(lines: [String], carries: [LexState]) {
        self.lines = lines
        self.carries = carries
    }
}

/// Avoids splitting and sequentially scanning the same code block on every SwiftUI body pass.
///
/// Code and language are both exact key fields because either can change line boundaries and the
/// lexer state carried into every following line.
@MainActor
private enum CodeBlockPreparationCache {
    private static let values: NSCache<CodeBlockPreparationKey, CodeBlockPreparation> = {
        let cache = NSCache<CodeBlockPreparationKey, CodeBlockPreparation>()
        cache.countLimit = 80
        cache.totalCostLimit = 8 * 1_024 * 1_024
        return cache
    }()

    /// The live tail's fence gets a cache of exactly one entry rather than a share of the one
    /// above, for the reason `MarkdownParseCache` wrote down for prose: a growing fence is one
    /// new prefix per delta, each seen for milliseconds and never again, and put through
    /// `values` a single streamed answer evicted every settled block's preparation, so the
    /// visible finished fences re-split and re-ran `CarryPass` on their next redraw.
    private static var streamed: (code: String, language: Language, value: CodeBlockPreparation)?

    static func prepared(code: String, language: Language, isStreaming: Bool) -> CodeBlockPreparation {
        if isStreaming {
            if let streamed, streamed.code == code, streamed.language == language {
                return streamed.value
            }
            let value = compute(code: code, language: language)
            streamed = (code, language, value)
            return value
        }

        let key = CodeBlockPreparationKey(code: code, language: language)
        if let cached = values.object(forKey: key) { return cached }
        let value = compute(code: code, language: language)
        values.setObject(value, forKey: key, cost: code.utf8.count)
        return value
    }

    private static func compute(code: String, language: Language) -> CodeBlockPreparation {
        let lines = code.components(separatedBy: "\n")
        return CodeBlockPreparation(
            lines: lines,
            carries: CarryPass.states(for: lines, language: language)
        )
    }
}
