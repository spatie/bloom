import SwiftUI
import AppKit
import BatonCore

/// Code gets a dedicated surface so syntax state can flow across lines without flattening the transcript.
public struct CodeBlockView: View {
    private let code: String
    private let language: Language
    private let showsLineNumbers: Bool
    @State private var copied = false
    @State private var showsAllLines = false

    public init(code: String, language: Language, showsLineNumbers: Bool = false) {
        self.code = code
        self.language = language
        self.showsLineNumbers = showsLineNumbers
    }

    public var body: some View {
        let prepared = CodeBlockPreparationCache.prepared(code: code, language: language)
        let visibleCount = showsAllLines ? prepared.lines.count : min(prepared.lines.count, 2_000)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Metrics.corner) {
                Text(Self.displayName(for: language))
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textTertiary)
                Spacer(minLength: Metrics.gutter)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.2))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(Typo.micro)
                        .foregroundStyle(copied ? Palette.positive : Palette.textTertiary)
                        .frame(width: Metrics.gutter, height: Metrics.gutter)
                }
                .buttonStyle(.plain)
                .help(copied ? "Copied" : "Copy code")
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, Metrics.corner)

            Hairline()

            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(0..<visibleCount, id: \.self) { offset in
                        HStack(alignment: .firstTextBaseline, spacing: Metrics.gutter) {
                            if showsLineNumbers {
                                Text(String(offset + 1))
                                    .font(Typo.codeSmall)
                                    .foregroundStyle(Palette.textTertiary)
                                    .monospacedDigit()
                                    .frame(minWidth: Metrics.titleBarHeight, alignment: .trailing)
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
                .padding(Metrics.gutter)
            }

            if prepared.lines.count > 2_000, !showsAllLines {
                Hairline()
                Button("Show all \(prepared.lines.count) lines") {
                    showsAllLines = true
                }
                .buttonStyle(.plain)
                .font(Typo.caption)
                .foregroundStyle(Palette.accent)
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, Metrics.corner)
            }
        }
        .background(Palette.surfaceSunken)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.corner))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.corner)
                .stroke(Palette.border, lineWidth: Metrics.hairline)
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

    static func prepared(code: String, language: Language) -> CodeBlockPreparation {
        let key = CodeBlockPreparationKey(code: code, language: language)
        if let cached = values.object(forKey: key) { return cached }

        let lines = code.components(separatedBy: "\n")
        let value = CodeBlockPreparation(
            lines: lines,
            carries: CarryPass.states(for: lines, language: language)
        )
        values.setObject(value, forKey: key, cost: code.utf8.count)
        return value
    }
}
