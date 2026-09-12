import SwiftUI
import BloomClient

/// The small SwiftUI inline adapter. Desktop keeps its cached native link and chip renderer.
enum BloomInlineText {
    static func render(
        _ inline: [MarkdownInline], role: BloomMarkdownInlineRole, colour: Color, scheme: ColorScheme, textStyle: Font.TextStyle = .body
    ) -> AttributedString {
        render(inline, font: font(role, textStyle: textStyle), colour: colour, scheme: scheme, intents: [])
    }

    private static func font(_ role: BloomMarkdownInlineRole, textStyle: Font.TextStyle) -> Font {
        switch role {
        case .body: .system(textStyle)
        case .heading(1): .title2.bold()
        case .heading(2): .title3.bold()
        case .heading: .system(textStyle).bold()
        case .tableHeader: .system(textStyle == .body ? .callout : textStyle).bold()
        case .tableCell: .system(textStyle == .body ? .callout : textStyle)
        }
    }

    private static func render(
        _ inline: [MarkdownInline], font: Font, colour: Color,
        scheme: ColorScheme, intents: InlinePresentationIntent
    ) -> AttributedString {
        var output = AttributedString()
        for value in inline {
            switch value {
            case .text(let text):
                output += run(text, font: font, colour: colour, intents: intents)
            case .lineBreak:
                output += run("\n", font: font, colour: colour, intents: intents)
            case .code(let text):
                var code = run(text, font: font.monospaced(), colour: colour, intents: intents)
                code.backgroundColor = BloomColour.resolve(PaletteInk.surfaceSunken, scheme: scheme)
                output += code
            case .emphasis(let children):
                output += render(children, font: font, colour: colour, scheme: scheme, intents: intents.union(.emphasized))
            case .strong(let children):
                output += render(children, font: font, colour: colour, scheme: scheme, intents: intents.union(.stronglyEmphasized))
            case .strikethrough(let children):
                var result = render(children, font: font, colour: colour, scheme: scheme, intents: intents)
                result.strikethroughStyle = .single
                output += result
            case .link(let children, let address):
                var result = render(children, font: font, colour: colour, scheme: scheme, intents: intents)
                if let url = URL(string: address), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                    result.link = url
                    result.foregroundColor = BloomColour.resolve(PaletteInk.accent, scheme: scheme)
                    result.underlineStyle = .single
                }
                output += result
            }
        }
        return output
    }

    private static func run(_ text: String, font: Font, colour: Color, intents: InlinePresentationIntent) -> AttributedString {
        var value = AttributedString(text)
        value.font = font
        value.foregroundColor = colour
        if !intents.isEmpty { value.inlinePresentationIntent = intents }
        return value
    }
}
