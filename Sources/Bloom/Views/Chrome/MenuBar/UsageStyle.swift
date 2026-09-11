import SwiftUI
import BloomCore

/// The usage panel's type and spacing scale, in its two densities. OpenUsage's `DensitySetting`,
/// value for value.
///
/// **Not `Typo` and not `Metrics`.** Those are Bloom's window scale, and this panel is drawn to
/// OpenUsage's measurements on OpenUsage's ground. See `UsagePanelView`.
struct UsageScale: Equatable {
    var label: CGFloat
    var supporting: CGFloat
    var header: CGFloat
    var headerIcon: CGFloat
    var plan: CGFloat
    var barRowPadding: CGFloat
    var meterHeight: CGFloat
    var textRowPadding: CGFloat
    var condensedTop: CGFloat
    var rowInner: CGFloat
    var section: CGFloat
    var headerToCard: CGFloat
    var cardGutter: CGFloat
    var controlRow: CGFloat
    var contentTop: CGFloat

    static func of(_ density: UsageDensity) -> UsageScale {
        // The system's headline size, which is thirteen points on a Mac, rather than a literal.
        let headline = NSFont.preferredFont(forTextStyle: .headline).pointSize
        switch density {
        case .regular:
            return UsageScale(
                label: headline, supporting: 12, header: 14, headerIcon: 16, plan: 11,
                barRowPadding: 10, meterHeight: 5, textRowPadding: 6, condensedTop: 2, rowInner: 4,
                section: 14, headerToCard: 4, cardGutter: 5, controlRow: 9, contentTop: 14
            )
        case .compact:
            return UsageScale(
                label: headline - 1, supporting: 11, header: 13, headerIcon: 14, plan: 10,
                barRowPadding: 5, meterHeight: 4, textRowPadding: 4, condensedTop: 1, rowInner: 3,
                section: 8, headerToCard: 2, cardGutter: 3, controlRow: 6, contentTop: 10
            )
        }
    }
}

extension EnvironmentValues {
    @Entry var usageScale = UsageScale.of(.regular)
}

/// The panel's colours, all of them system semantic colours so both appearances and Increase
/// Contrast come for free.
///
/// The meter has no green. A window that is fine is the ordinary case, and blue says "a quantity"
/// without saying "good"; yellow and red are the news.
enum UsageInk {
    static var tray: Color { Color(nsColor: .textBackgroundColor) }
    static var card: Color { Color(nsColor: .quaternarySystemFill) }
    static var normal: Color { Color(nsColor: .systemBlue) }
    static var warning: Color { Color(nsColor: .systemYellow) }
    static var critical: Color { Color(nsColor: .systemRed) }

    static func tone(_ tone: UsageMeterReading.Tone) -> Color {
        switch tone {
        case .normal: normal
        case .warning: warning
        case .critical: critical
        case .empty: .clear
        }
    }
}

enum UsageMotion {
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.8)
}

extension View {
    /// A borderless rounded card on the panel's ground.
    func usageCard() -> some View {
        background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(UsageInk.card)
        }
    }

    /// A tooltip that appears inside the panel after a short dwell.
    ///
    /// Not `.help()`, because the system's tooltips are shown for the active application and the
    /// panel never activates Bloom: every hover in it would come up empty.
    func usageTooltip(_ text: String?) -> some View {
        modifier(UsageTooltipModifier(text: text))
    }
}

private struct UsageTooltipModifier: ViewModifier {
    let text: String?
    @Environment(UsagePanelModel.self) private var model
    @State private var frame: CGRect = .zero
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        if let text, !text.isEmpty {
            content
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .named(UsagePanelView.coordinateSpace))
                } action: { frame = $0 }
                .onHover { inside in
                    pending?.cancel()
                    if inside {
                        pending = Task {
                            try? await Task.sleep(for: .milliseconds(400))
                            guard !Task.isCancelled else { return }
                            model.tooltip = UsagePanelModel.Tooltip(text: text, anchor: frame)
                        }
                    } else if model.tooltip?.text == text {
                        model.tooltip = nil
                    }
                }
        } else {
            content
        }
    }
}

/// Draws the one tooltip the panel is showing, above its anchor, or below when there is no room.
///
/// **The text is set at an explicit width, never a maximum.** The first version framed it with a
/// `maxWidth` and then fixed the whole bubble to its ideal size, and those two disagree: the ideal
/// size of a paragraph is one unbroken line, so the bubble was drawn for one or two lines while
/// the text inside wrapped to three and spilled over the rows beneath. So the text's one line
/// width is measured first, the bubble is that wide or `maximumWidth`, whichever is less, and the
/// height follows from the wrap at that width.
struct UsageTooltipLayer: View {
    let tooltip: UsagePanelModel.Tooltip?
    @State private var size: CGSize = .zero
    @State private var lineWidth: CGFloat = 0

    private static let maximumWidth: CGFloat = 240
    private static let font = Font.system(size: 12)

    var body: some View {
        GeometryReader { proxy in
            if let tooltip {
                let x = min(max(tooltip.anchor.midX - size.width / 2, 6), max(6, proxy.size.width - size.width - 6))
                let above = tooltip.anchor.minY - 8 - size.height
                let y = above >= 4 ? above : tooltip.anchor.maxY + 8
                Text(tooltip.text)
                    .font(Self.font)
                    .multilineTextAlignment(.center)
                    .frame(width: min(max(lineWidth, 1), Self.maximumWidth))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color(nsColor: .windowBackgroundColor))
                            .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(.separator, lineWidth: 0.5)
                    }
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                    .offset(x: x, y: y)
                    .transition(.opacity)
            }
        }
        .background {
            // The unbroken line, measured out of sight, which is what decides the bubble's width.
            if let tooltip {
                Text(tooltip.text)
                    .font(Self.font)
                    .fixedSize()
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { lineWidth = $0 }
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.12), value: tooltip)
    }
}

/// The small header over a card that is not a provider's: a symbol and a title.
struct UsageSectionHeader: View {
    let symbol: String
    let title: String
    @Environment(\.usageScale) private var scale

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: scale.headerIcon * 0.75, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: scale.headerIcon, height: scale.headerIcon)
            Text(title)
                .font(.system(size: scale.header, weight: .semibold))
            Spacer(minLength: 0)
        }
        .padding(.leading, 2)
        .padding(.vertical, 2)
        .padding(.horizontal, 8)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A row that goes somewhere else: a symbol, a title with a line under it, and a chevron.
struct UsageLinkRow: View {
    let symbol: String
    let title: String
    let detail: String
    let action: () -> Void
    @Environment(\.usageScale) private var scale

    var body: some View {
        UsageHoverRow(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: scale.label, weight: .semibold))
                    Text(detail)
                        .font(.system(size: scale.plan))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, scale.controlRow - 4)
        }
    }
}

/// A full width row button with a quiet highlight under the pointer, for the lists in the panel.
struct UsageHoverRow<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            label
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(isHovering ? 0.06 : 0))
                        .padding(.horizontal, 6)
                }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
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

/// The provider's mark, or its SF Symbol stand-in for a provider with no mark of its own.
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
