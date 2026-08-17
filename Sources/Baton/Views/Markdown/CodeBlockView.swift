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
        let allLines = code.components(separatedBy: "\n")
        let visibleCount = showsAllLines ? allLines.count : min(allLines.count, 2_000)
        let highlighted = Self.highlight(lines: Array(allLines.prefix(visibleCount)), language: language)

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
                    ForEach(Array(highlighted.enumerated()), id: \.offset) { offset, line in
                        HStack(alignment: .firstTextBaseline, spacing: Metrics.gutter) {
                            if showsLineNumbers {
                                Text(String(offset + 1))
                                    .font(Typo.codeSmall)
                                    .foregroundStyle(Palette.textTertiary)
                                    .monospacedDigit()
                                    .frame(minWidth: 24, alignment: .trailing)
                            }
                            Text(line)
                                .font(Typo.code)
                                .foregroundStyle(Palette.textPrimary)
                                .textSelection(.enabled)
                        }
                        .frame(minHeight: 16)
                    }
                }
                .padding(Metrics.gutter)
            }

            if allLines.count > 2_000, !showsAllLines {
                Hairline()
                Button("Show all \(allLines.count) lines") {
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

    private static func highlight(lines: [String], language: Language) -> [AttributedString] {
        var state = LexState()
        return lines.map { line in
            let tokens = SyntaxHighlighter.tokenize(line: line, language: language, carry: &state)
            var attributed = AttributedString(line)
            attributed.font = Typo.code
            attributed.foregroundColor = Palette.textPrimary
            let utf16Count = line.utf16.count

            for token in tokens {
                guard token.range.lowerBound >= 0,
                      token.range.upperBound <= utf16Count,
                      token.range.lowerBound < token.range.upperBound else { continue }
                let lowerString = String.Index(utf16Offset: token.range.lowerBound, in: line)
                let upperString = String.Index(utf16Offset: token.range.upperBound, in: line)
                guard let lower = AttributedString.Index(lowerString, within: attributed),
                      let upper = AttributedString.Index(upperString, within: attributed),
                      lower <= upper else { continue }
                attributed[lower..<upper].foregroundColor = color(for: token.kind)
            }
            return attributed
        }
    }

    static func color(for kind: TokenKind) -> Color {
        switch kind {
        case .plain, .punctuation:
            Palette.textPrimary
        case .keyword:
            Palette.synKeyword
        case .type:
            Palette.synType
        case .string, .regex:
            Palette.synString
        case .number:
            Palette.synNumber
        case .comment:
            Palette.synComment
        case .function:
            Palette.synFunction
        case .variable:
            Palette.synVariable
        case .attribute:
            Palette.synAttribute
        case .operator:
            Palette.synOperator
        case .constant:
            Palette.synConstant
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
