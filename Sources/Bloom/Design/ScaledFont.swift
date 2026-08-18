import SwiftUI
import AppKit

/// A rung of `Typo` that has not been resolved to a point size yet.
///
/// It exists because macOS has no Dynamic Type and SwiftUI does not fake one. Measured on this
/// machine, `Text("Hamburgefonstiv").font(.system(.body))` renders 105x16 points at every value of
/// `\.dynamicTypeSize` from `.xSmall` through `.accessibility5`, and `.headline`, `.callout`,
/// `.footnote` and the monospaced designs are identical at both ends of that range too. So a text
/// size setting cannot be an environment value SwiftUI already honours; it has to be one Bloom
/// resolves for itself.
///
/// Doing that in the *type* of a rung rather than at its call sites is what keeps the setting
/// scoped without touching the two hundred places that set a font. `.font(Typo.body)` picks the
/// overload below, which reads the scale out of the environment where the text actually is, so one
/// unchanged expression is 13 points in the sidebar and 20 in a transcript that was asked to be
/// larger, and neither call site knows the difference.
struct ScaledFont: Hashable, Sendable {
    /// What the rung is when nothing has scaled it, kept verbatim rather than rebuilt from a point
    /// size. An unscaled Bloom therefore renders exactly what it rendered before this existed:
    /// `.headline` stays the system's heading style, which is what lets macOS treat it as one.
    private let unscaled: Font
    private let style: Font.TextStyle
    /// Only set where the rung deviates from the weight the text style ships with. Where it is
    /// nil the scaled form takes the style's own weight, which is how `.headline` stays bold.
    private let weight: Font.Weight?
    private let design: Font.Design

    init(_ style: Font.TextStyle, weight: Font.Weight? = nil, design: Font.Design = .default) {
        self.style = style
        self.weight = weight
        self.design = design
        let base = Font.system(style, design: design)
        unscaled = weight.map { base.weight($0) } ?? base
    }

    /// Rounded to a whole point, because a text style is a whole point everywhere else in macOS and
    /// a scale that lands on 14.95 renders a hair off the metrics every neighbouring control uses.
    /// The five rungs stay distinct at every scale the settings window offers.
    ///
    /// A monospaced rung keeps the system's monospaced face whatever `face` is. Code, paths and
    /// diff stats line up in a column because they are all one face, and a prose face chosen for
    /// paragraphs is not a face whose columns line up.
    func resolved(scale: CGFloat, face: ChatFont = .system) -> Font {
        let wantsFace = face != .system && design != .monospaced
        guard scale != 1 || wantsFace else { return unscaled }
        let base = NSFont.preferredFont(forTextStyle: style.appKitStyle)
        let size = (base.pointSize * scale).rounded()
        let resolvedWeight = weight ?? base.systemWeight
        guard wantsFace else {
            return Font.system(size: size, weight: resolvedWeight, design: design)
        }
        return face.font(size: size, weight: resolvedWeight)
    }

    /// The monospaced companion for a span of code sitting inside a run of this rung.
    ///
    /// Its own method rather than `resolved(...).monospaced()`, because that expression only means
    /// anything on a system font: on a `Font.custom` face SwiftUI cannot swap the design, so it
    /// substitutes whatever monospaced face CoreText offers and the code in a paragraph silently
    /// changes width. Asking for the system monospaced face by size says what is wanted, and it is
    /// also the only way to apply `ChatFont.inlineCodeScale`, which is what keeps a mono run from
    /// reading a size larger than the sentence it is in.
    func monospacedCompanion(scale: CGFloat, face: ChatFont = .system) -> Font {
        let base = NSFont.preferredFont(forTextStyle: style.appKitStyle)
        let size = (base.pointSize * scale * face.inlineCodeScale).rounded()
        return Font.system(size: size, weight: weight ?? base.systemWeight, design: .monospaced)
    }
}

extension View {
    /// Overloads SwiftUI's own `font(_:)`, which is the point: it means a rung can start carrying a
    /// scale without any of the call sites that set one being edited.
    func font(_ font: ScaledFont) -> some View {
        modifier(ScaledFontModifier(font: font))
    }
}

private struct ScaledFontModifier: ViewModifier {
    let font: ScaledFont

    @Environment(\.fontScale) private var scale
    @Environment(\.chatFont) private var face

    func body(content: Content) -> some View {
        content.font(font.resolved(scale: scale, face: face))
    }
}

extension EnvironmentValues {
    /// Multiplies every rung of `Typo` inside a subtree. One everywhere except the conversation,
    /// which is the only surface the user reads rather than scans, and the only one macOS does not
    /// already offer a system-wide size control for.
    @Entry var fontScale: CGFloat = 1
}

private extension Font.TextStyle {
    /// The AppKit style each SwiftUI style is the same thing as, so a point size can be asked for
    /// rather than guessed at. Newer styles fall back to the body size rather than to a literal:
    /// `Typo` uses none of them, and a rung that appears later should read as text, not as a title.
    var appKitStyle: NSFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .body: .body
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }
}

private extension NSFont {
    /// The weight the system font was actually vended at. Read off the descriptor rather than
    /// assumed regular, because macOS sets `.headline` at 0.4, which is bold: assuming otherwise
    /// would have turned every heading in a scaled transcript back into a plain sentence.
    var systemWeight: Font.Weight {
        let traits = fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        let value = traits?[.weight] as? CGFloat ?? 0
        return switch value {
        case ..<(-0.4): .ultraLight
        case ..<(-0.2): .thin
        case ..<(-0.05): .light
        case ..<0.15: .regular
        case ..<0.27: .medium
        case ..<0.35: .semibold
        case ..<0.5: .bold
        case ..<0.7: .heavy
        default: .black
        }
    }
}
