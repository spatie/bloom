import SwiftUI
import AppKit
import BloomCore

/// Code gets a dedicated surface so syntax state can flow across lines without flattening the transcript.
public struct CodeBlockView: View {
    /// Beyond this the fence is folded, because a fence nobody asked to see all of is not worth
    /// lexing and laying out all of on the way past it.
    private static let lineCap = 2_000

    private let code: String
    private let language: Language
    @State private var showsAllLines = false

    /// Whether the answer this fence belongs to is still arriving, which decides which cache the
    /// preparation goes through. See `CodeBlockPreparationCache`.
    @Environment(\.markdownIsStreaming) private var isStreaming

    public init(code: String, language: Language) {
        self.code = code
        self.language = language
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
                CopyButton(text: code, title: "Copy code", size: MarkdownMetrics.iconButton)
            }
            .padding(.horizontal, MarkdownMetrics.blockGap)
            .padding(.vertical, Metrics.spacing)

            Hairline()

            ScrollView(.horizontal) {
                Text(highlighted(prepared, upTo: visibleCount))
                    .font(Typo.code)
                    .foregroundStyle(Palette.textPrimary)
                    .textSelection(.enabled)
                    .padding(MarkdownMetrics.blockGap)
            }

            // No `!showsAllLines`: an opened fence keeps the control, now reading the other way.
            // A fence unfolded once could not be folded again, and two thousand lines is a lot of
            // pane to have put between the reader and whatever they were scrolling towards.
            if prepared.lines.count > Self.lineCap {
                Hairline()
                Button(TextFold.title(isExpanded: showsAllLines, lines: prepared.lines.count)) {
                    showsAllLines.toggle()
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
                .strokeBorder(Palette.border, lineWidth: Metrics.outline)
        }
    }

    /// The visible lines as one `AttributedString`, highlighting and all.
    ///
    /// **One `Text` rather than a `Text` per line, so a selection runs across the whole fence.**
    /// Sibling `Text`s are separate selection scopes, so dragging down a forty line block selected
    /// the single line the drag began on, and Copy, which takes the whole fence, was the only way
    /// to get anything out of one. Lifting three lines out of forty is not what Copy does, and in
    /// a transcript full of code it is most of what anybody wants. `WorkspaceEventsView.marked`
    /// reached the same conclusion about a setup log and wrote the rule down.
    ///
    /// Joining costs the colours nothing. `SyntaxCache.attributed` hands back a line whose colours
    /// are already attribute runs on the string, concatenation carries a run's attributes with it,
    /// and the lexer state that a fence opening a comment on line three needs still arrives per
    /// line through `prepared.carries`. It saves the view hierarchy two thousand views at the cap,
    /// which the transcript's scrolling pays for on every display cycle.
    ///
    /// The line number gutter came off with the `ForEach`. It was a parameter defaulting to false
    /// that no caller ever set, so the column had never been drawn; a column beside one `Text` is
    /// a different problem from a column beside one `Text` per line, and it wants a per line height
    /// the way `SetupLineHeight` gives the setup log one. Worth writing when something asks for it.
    private func highlighted(_ prepared: CodeBlockPreparation, upTo count: Int) -> AttributedString {
        var output = AttributedString()
        for offset in 0..<count {
            if offset > 0 { output += AttributedString("\n") }
            output += SyntaxCache.attributed(
                line: prepared.lines[offset],
                language: language,
                carry: prepared.carries[offset]
            )
        }
        return output
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
private enum CodeBlockPreparationCache {
    /// **Bounded by bytes, not by fences**, which is the conclusion `TranscriptEventCache` reached
    /// and this never revisited. It was 80, which is a screen of them rather than a session: one
    /// scroll up a long transcript evicted every settled fence and re-split and re-carried all of
    /// them on the way back. The eight megabytes below is what was already doing the bounding.
    ///
    /// `nonisolated(unsafe)` for `SyntaxCache`'s reason and on the same two legs: `NSCache` does
    /// its own locking, and a `CodeBlockPreparation` is a `final class` holding two `let`s of
    /// `Sendable` value types, so nothing a reader gets out of it can be written by anybody. The
    /// key is immutable in the same way.
    nonisolated(unsafe) private static let values: NSCache<CodeBlockPreparationKey, CodeBlockPreparation> = {
        let cache = NSCache<CodeBlockPreparationKey, CodeBlockPreparation>()
        cache.countLimit = 0
        cache.totalCostLimit = 8 * 1_024 * 1_024
        return cache
    }()

    /// The live tail's fence gets a cache of exactly one entry rather than a share of the one
    /// above, for the reason `MarkdownParseCache` wrote down for prose: a growing fence is one
    /// new prefix per delta, each seen for milliseconds and never again, and put through
    /// `values` a single streamed answer filled it with prefixes nobody will ask for again, so
    /// the visible finished fences re-split and re-ran `CarryPass` on their next redraw.
    ///
    /// **The main actor's, and it stays there.** `values` is an `NSCache` and does its own
    /// locking; this is a plain `var`, so it is the one thing here a preparation pass may not
    /// touch. Nothing off the main actor has a live tail to draw anyway.
    @MainActor private static var streamed: (code: String, language: Language, value: CodeBlockPreparation)?

    @MainActor static func prepared(code: String, language: Language, isStreaming: Bool) -> CodeBlockPreparation {
        guard isStreaming else { return settled(code: code, language: language) }
        if let streamed, streamed.code == code, streamed.language == language {
            return streamed.value
        }
        let value = compute(code: code, language: language)
        streamed = (code, language, value)
        return value
    }

    /// The settled cache alone, which is the half a preparation pass off the main actor may fill.
    static func settled(code: String, language: Language) -> CodeBlockPreparation {
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

/// Splitting and carrying a settled fence before anything asks for it. See `TranscriptPrime`.
///
/// A function rather than the cache widened, for `MarkdownPrime`'s reason: what the cache holds is
/// this file's own type and there is nothing to hand out.
enum CodeBlockPrime {
    static func prepare(code: String, language: Language) {
        _ = CodeBlockPreparationCache.settled(code: code, language: language)
    }
}
