import SwiftUI
import BloomCore

/// The type and the ink the limits are drawn in, which are the menu's and never Bloom's.
///
/// **This block hangs in an `NSMenu`, on the menu's own vibrant material, with real menu items above
/// and below it.** A row of system chrome wearing the app's palette reads as something pasted onto
/// the menu rather than as one of its rows, and that is not a guess: the first version of this panel
/// used `Palette` and `Typo`, and photographed on a light menu its secondary text measured about
/// three to one against the material beside a jet black menu item one row below.
///
/// So every colour here is an AppKit semantic one and every size comes from `NSFont.menuFont`,
/// which is thirteen or fourteen points depending on the machine. They resolve against the menu's
/// own effective appearance exactly as its items do, in both appearances, on any accent, and with
/// Increase Contrast switched on.
enum UsageScale {
    /// A metric's name, at the size the menu sets its own rows.
    static var label: Font { Font(NSFont.menuFont(ofSize: 0)).weight(.semibold) }
    /// The figure, the countdown, the status: one point down.
    static var supporting: Font { Font(NSFont.menuFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize - 1)) }
    /// A provider's name.
    static var header: Font { Font(NSFont.menuFont(ofSize: 0)).weight(.semibold) }
    /// The plan beside it, and "Outdated": two points down.
    static var plan: Font { Font(NSFont.menuFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize - 2)) }
    /// Between one provider's block and the next.
    static let section: CGFloat = 12
}

/// The ink a view hosted in an `NSMenu` is drawn in.
enum MenuInk {
    /// A row label: the same ink AppKit draws a menu item's title in.
    static var primary: Color { Color(nsColor: .labelColor) }
    /// Anything read off the row beside it: a countdown, a plan, a note.
    static var secondary: Color { Color(nsColor: .secondaryLabelColor) }
    /// "Outdated", which is a caveat rather than news.
    static var tertiary: Color { Color(nsColor: .tertiaryLabelColor) }
    /// The empty part of a meter.
    static var track: Color { Color(nsColor: .tertiaryLabelColor) }
    /// The card a provider's rows sit on. Quiet enough to group them without drawing a box.
    static var card: Color { Color(nsColor: .quaternarySystemFill) }

    static var normal: Color { Color(nsColor: .systemBlue) }
    static var warning: Color { Color(nsColor: .systemYellow) }
    static var critical: Color { Color(nsColor: .systemRed) }

    /// The meter's colour is a verdict on the rate, not on the level: see `UsagePace`.
    static func tone(_ tone: UsageMeterReading.Tone) -> Color {
        switch tone {
        case .normal: normal
        case .warning: warning
        case .critical: critical
        case .empty: .clear
        }
    }
}

/// A provider's mark as a shape, filled in whatever style it is given.
struct ProviderMarkShape: Shape {
    let mark: SVGPath
    var inset: CGFloat = 0.04

    func path(in rect: CGRect) -> Path {
        let bounds = mark.bounds
        guard bounds.width > 0, bounds.height > 0 else { return Path() }
        let available = rect.insetBy(dx: rect.width * inset, dy: rect.height * inset)
        let scale = min(available.width / bounds.width, available.height / bounds.height)
        let dx = available.midX - bounds.midX * scale
        let dy = available.midY - bounds.midY * scale
        func point(_ source: CGPoint) -> CGPoint {
            CGPoint(x: source.x * scale + dx, y: source.y * scale + dy)
        }
        var path = Path()
        for command in mark.commands {
            switch command {
            case .move(let to): path.move(to: point(to))
            case .line(let to): path.addLine(to: point(to))
            case .curve(let to, let first, let second):
                path.addCurve(to: point(to), control1: point(first), control2: point(second))
            case .quad(let to, let control): path.addQuadCurve(to: point(to), control: point(control))
            case .close: path.closeSubpath()
            }
        }
        return path
    }
}

/// The provider's own mark, or its SF Symbol stand-in for a provider with no mark of its own.
struct ProviderMarkView: View {
    let provider: AgentKind

    var body: some View {
        if let mark = ProviderMark.path(for: provider) {
            ProviderMarkShape(mark: mark)
                .accessibilityHidden(true)
        } else {
            Image(systemName: PaneGlyph.agentMark(for: provider))
                .resizable()
                .scaledToFit()
                .accessibilityHidden(true)
        }
    }
}
