import SwiftUI
import AppKit

/// Baton's colours. Every colour is defined once here, as a dynamic NSColor so light and dark
/// resolve without an asset catalogue (the app is built by SwiftPM, which has none).
enum Palette {
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    // Surfaces, from the back of the window forward.
    static let windowBackground = dynamic(light: 0xF2F2F0, dark: 0x1A1A1C)
    static let sidebar = dynamic(light: 0xF7F7F5, dark: 0x1E1E20)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x242427)
    static let surfaceRaised = dynamic(light: 0xFFFFFF, dark: 0x2B2B2F)
    static let surfaceSunken = dynamic(light: 0xF4F4F2, dark: 0x1B1B1D)
    static let hover = dynamic(light: 0x00000009, dark: 0xFFFFFF0D)
    static let selected = dynamic(light: 0x00000014, dark: 0xFFFFFF18)

    // Lines.
    static let border = dynamic(light: 0x00000014, dark: 0xFFFFFF14)
    static let borderStrong = dynamic(light: 0x00000026, dark: 0xFFFFFF26)

    // Text.
    static let textPrimary = dynamic(light: 0x1C1C1E, dark: 0xEDEDEF)
    static let textSecondary = dynamic(light: 0x6B6B70, dark: 0x9C9CA3)
    static let textTertiary = dynamic(light: 0x9A9AA0, dark: 0x6E6E76)
    static let textInverted = dynamic(light: 0xFFFFFF, dark: 0x16161A)

    // Meaning.
    static let accent = dynamic(light: 0x2F6FED, dark: 0x5B8DEF)
    static let positive = dynamic(light: 0x1A7F4B, dark: 0x3FBF7F)
    static let negative = dynamic(light: 0xC03030, dark: 0xF06A6A)
    static let warning = dynamic(light: 0xB07908, dark: 0xE0A93B)
    static let running = dynamic(light: 0x2F6FED, dark: 0x5B8DEF)

    // Diffs.
    static let diffAddBackground = dynamic(light: 0xE4F6E9, dark: 0x14351F)
    static let diffAddEmphasis = dynamic(light: 0xB6E7C4, dark: 0x1F5B33)
    static let diffDeleteBackground = dynamic(light: 0xFCE8E8, dark: 0x3A1A1A)
    static let diffDeleteEmphasis = dynamic(light: 0xF5C2C2, dark: 0x5E2626)
    static let diffGutter = dynamic(light: 0xFAFAF8, dark: 0x1F1F22)

    // Syntax, mapped from BatonCore's TokenKind in CodeView.
    static let synKeyword = dynamic(light: 0x9B2393, dark: 0xD08EE0)
    static let synType = dynamic(light: 0x0B7285, dark: 0x5BC8DB)
    static let synString = dynamic(light: 0xC0392B, dark: 0xE8846E)
    static let synNumber = dynamic(light: 0x1C6FBB, dark: 0x7FB3F0)
    static let synComment = dynamic(light: 0x8A8A8F, dark: 0x76767E)
    static let synFunction = dynamic(light: 0x2F5FD0, dark: 0x89AFF5)
    static let synVariable = dynamic(light: 0x6A3FB5, dark: 0xB49BF0)
    static let synAttribute = dynamic(light: 0x8A6A00, dark: 0xD9B65C)
    static let synOperator = dynamic(light: 0x5A5A60, dark: 0xA8A8B0)
    static let synConstant = dynamic(light: 0x1C6FBB, dark: 0x7FB3F0)
}

/// Type scale. The app is dense on purpose: a workspace list and a transcript both want to show
/// a lot at once, so nothing here is larger than the macOS body size.
enum Typo {
    static let title = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 13)
    static let bodyEmphasis = Font.system(size: 13, weight: .medium)
    static let label = Font.system(size: 12)
    static let labelEmphasis = Font.system(size: 12, weight: .medium)
    static let caption = Font.system(size: 11)
    static let captionEmphasis = Font.system(size: 11, weight: .medium)
    static let micro = Font.system(size: 10, weight: .medium)

    static let code = Font.system(size: 12, design: .monospaced)
    static let codeSmall = Font.system(size: 11, design: .monospaced)
    static let codeTiny = Font.system(size: 10, design: .monospaced)
}

enum Metrics {
    static let sidebarWidth: CGFloat = 260
    static let inspectorWidth: CGFloat = 380
    static let rowHeight: CGFloat = 26
    static let corner: CGFloat = 6
    static let cornerSmall: CGFloat = 4
    static let gutter: CGFloat = 12
    static let hairline: CGFloat = 1
}

extension NSColor {
    /// Accepts 0xRRGGBB and 0xRRGGBBAA. The alpha form is how the overlay colours above are
    /// written, so a hover tint works over any surface.
    convenience init(hex: UInt32) {
        let hasAlpha = hex > 0xFFFFFF
        let red, green, blue, alpha: CGFloat
        if hasAlpha {
            red = CGFloat((hex >> 24) & 0xFF) / 255
            green = CGFloat((hex >> 16) & 0xFF) / 255
            blue = CGFloat((hex >> 8) & 0xFF) / 255
            alpha = CGFloat(hex & 0xFF) / 255
        } else {
            red = CGFloat((hex >> 16) & 0xFF) / 255
            green = CGFloat((hex >> 8) & 0xFF) / 255
            blue = CGFloat(hex & 0xFF) / 255
            alpha = 1
        }
        self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

extension Color {
    /// Repo accent colours are stored as plain hex strings in SQLite.
    init(hexString: String) {
        let cleaned = hexString.hasPrefix("#") ? String(hexString.dropFirst()) : hexString
        self.init(nsColor: NSColor(hex: UInt32(cleaned, radix: 16) ?? 0x4C8DF6))
    }
}

// MARK: - Reusable chrome

/// A one-pixel separator that stays one physical pixel on Retina.
struct Hairline: View {
    var axis: Axis = .horizontal

    var body: some View {
        Rectangle()
            .fill(Palette.border)
            .frame(
                width: axis == .vertical ? Metrics.hairline : nil,
                height: axis == .horizontal ? Metrics.hairline : nil
            )
    }
}

/// The small rounded label used for tool names, file chips, counts and states.
struct Chip: View {
    var text: String
    var systemImage: String?
    var tint: Color = Palette.textSecondary
    var background: Color = Palette.surfaceSunken
    var monospaced: Bool = false

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .font(monospaced ? Typo.codeTiny : Typo.micro)
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(background, in: RoundedRectangle(cornerRadius: Metrics.cornerSmall))
    }
}

/// `+118 -4` as seen next to a workspace in the sidebar.
struct DiffStatLabel: View {
    var additions: Int
    var deletions: Int
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            if additions > 0 {
                Text("+\(Self.abbreviate(additions))")
                    .foregroundStyle(Palette.positive)
            }
            if deletions > 0 {
                Text("-\(Self.abbreviate(deletions))")
                    .foregroundStyle(Palette.negative)
            }
        }
        .font(compact ? Typo.codeTiny : Typo.micro)
        .monospacedDigit()
    }

    /// 2.8k rather than 2793, because the sidebar has no room for the exact number.
    static func abbreviate(_ value: Int) -> String {
        if value < 1_000 { return String(value) }
        let thousands = Double(value) / 1_000
        return thousands < 10
            ? String(format: "%.1fk", thousands)
            : String(format: "%.0fk", thousands)
    }
}

/// Rows in the sidebar and the file list share this hover and selection treatment.
struct RowBackground: ViewModifier {
    var isSelected: Bool
    var isHovered: Bool

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: Metrics.corner)
                    .fill(isSelected ? Palette.selected : (isHovered ? Palette.hover : .clear))
            }
    }
}

extension View {
    func rowBackground(isSelected: Bool, isHovered: Bool) -> some View {
        modifier(RowBackground(isSelected: isSelected, isHovered: isHovered))
    }

    /// Tracks hover without each call site needing its own @State.
    func onHoverChange(_ handler: @escaping (Bool) -> Void) -> some View {
        onHover(perform: handler)
    }
}

/// A spinner that does not animate when nothing is running, because a dozen idle workspaces
/// each animating a spinner is a measurable amount of CPU.
struct ActivityDot: View {
    var isActive: Bool
    var tint: Color = Palette.running

    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(isActive ? tint : Palette.textTertiary.opacity(0.4))
            .frame(width: 6, height: 6)
            .scaleEffect(isActive && pulse ? 1.35 : 1)
            .opacity(isActive && pulse ? 0.5 : 1)
            .animation(
                isActive ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default,
                value: pulse
            )
            .onChange(of: isActive, initial: true) { _, active in
                pulse = active
            }
    }
}
