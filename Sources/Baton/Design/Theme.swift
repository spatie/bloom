import SwiftUI
import AppKit

/// Baton's colours.
///
/// Almost everything here resolves to an AppKit semantic colour rather than a hand-picked hex
/// value. That is deliberate: semantic colours already track light and dark, the user's accent
/// colour, increased contrast, reduce transparency, and the vibrancy of whatever material they
/// are drawn on. Hard-coded hexes track none of that, which is what made the first version of
/// this app look like a web page pretending to be a Mac.
///
/// The exceptions are the diff and syntax colours, which have to be specific hues, and even
/// those are defined once here rather than at their call sites.
enum Palette {
    // MARK: Surfaces

    /// Behind everything. The sidebar draws a real material over this.
    static let windowBackground = Color(nsColor: .windowBackgroundColor)

    /// Only used as a fallback where a material cannot be installed. Prefer `SidebarMaterial`.
    static let sidebar = Color(nsColor: .windowBackgroundColor)

    /// Content areas: the transcript, the inspector, anything holding text.
    static let surface = Color(nsColor: .textBackgroundColor)

    /// A card or control sitting on `surface`, such as the composer box.
    static let surfaceRaised = Color(nsColor: .controlBackgroundColor)

    /// A recessed strip: gutters, tool detail blocks, the bottom panel.
    static let surfaceSunken = Color(nsColor: .underPageBackgroundColor)

    // MARK: Overlays
    //
    // These are neutral tints painted over whatever is underneath, so they are expressed as an
    // opacity on the primary label colour rather than as a colour of their own. Writing them as
    // 0xRRGGBBAA was the original bug behind the solid black selection bar: 0x00000014 is the
    // number 20, indistinguishable from an opaque dark blue, so the alpha was never applied.

    static let hover = Color.primary.opacity(0.06)
    static let selected = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    /// Selection in a focused list inside the key window, where macOS uses the accent colour.
    static let selectedEmphasized = Color(nsColor: .selectedContentBackgroundColor)
    static let selectedEmphasizedText = Color(nsColor: .alternateSelectedControlTextColor)

    // MARK: Lines

    static let border = Color(nsColor: .separatorColor)
    static let borderStrong = Color(nsColor: .gridColor)

    // MARK: Text

    static let textPrimary = Color(nsColor: .labelColor)
    static let textSecondary = Color(nsColor: .secondaryLabelColor)
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)
    static let textInverted = Color(nsColor: .alternateSelectedControlTextColor)

    /// What a field says before anything is typed into it. Half ink, where the tertiary label is
    /// a quarter, which is why a placeholder written as `textTertiary` reads as disabled.
    static let textPlaceholder = Color(nsColor: .placeholderTextColor)

    // MARK: Text editing
    //
    // The three colours AppKit uses inside a text view. Each of them tracks something the accent
    // colour alone does not: the focus ring follows the Full Keyboard Access setting, the caret
    // follows the text colour on high contrast, and the selection is the paler fill a text run
    // gets rather than the solid one a list row gets.

    /// The focus ring around the control that has keyboard focus.
    static let focusRing = Color(nsColor: .keyboardFocusIndicatorColor)
    /// The caret.
    static let caret = Color(nsColor: .textInsertionPointColor)
    /// Selected text inside an editable or selectable text view.
    static let textSelection = Color(nsColor: .selectedTextBackgroundColor)

    // MARK: Meaning

    /// The user's chosen accent colour, not a blue we picked for them.
    static let accent = Color(nsColor: .controlAccentColor)
    static let positive = Color(nsColor: .systemGreen)
    static let negative = Color(nsColor: .systemRed)
    static let warning = Color(nsColor: .systemOrange)
    static let running = Color(nsColor: .controlAccentColor)

    // MARK: Diffs
    //
    // Tinted backgrounds, kept low in saturation so a wall of them is still readable, and
    // defined per appearance because a light green that works on white is invisible on charcoal.

    static let diffAddBackground = dynamic(light: 0xE6F4EA, dark: 0x14301E)
    static let diffAddEmphasis = dynamic(light: 0xB7E3C4, dark: 0x1F5233)
    static let diffDeleteBackground = dynamic(light: 0xFCEAEA, dark: 0x35191A)
    static let diffDeleteEmphasis = dynamic(light: 0xF5C6C6, dark: 0x5C2527)
    static let diffGutter = Color(nsColor: .underPageBackgroundColor)

    // MARK: Syntax

    static let synKeyword = dynamic(light: 0x9B2393, dark: 0xD08EE0)
    static let synType = dynamic(light: 0x0B7285, dark: 0x5BC8DB)
    static let synString = dynamic(light: 0xC0392B, dark: 0xE8846E)
    static let synNumber = dynamic(light: 0x1C6FBB, dark: 0x7FB3F0)
    static let synComment = dynamic(light: 0x7F8C8D, dark: 0x76767E)
    static let synFunction = dynamic(light: 0x2F5FD0, dark: 0x89AFF5)
    static let synVariable = dynamic(light: 0x6A3FB5, dark: 0xB49BF0)
    static let synAttribute = dynamic(light: 0x8A6A00, dark: 0xD9B65C)
    static let synOperator = dynamic(light: 0x5A5A60, dark: 0xA8A8B0)
    static let synConstant = dynamic(light: 0x1C6FBB, dark: 0x7FB3F0)

    /// A colour that differs between appearances, for the few cases where no semantic colour
    /// means the right thing. Both arguments are plain 0xRRGGBB.
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light)
        })
    }
}

extension NSColor {
    /// Plain 0xRRGGBB. There is deliberately no packed-alpha form: alpha belongs in
    /// `Color.opacity`, where it cannot be mistaken for part of the colour.
    convenience init(rgb: UInt32) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Color {
    /// Repo accent colours are stored as plain hex strings in SQLite.
    init(hexString: String) {
        let cleaned = hexString.hasPrefix("#") ? String(hexString.dropFirst()) : hexString
        self.init(nsColor: NSColor(rgb: UInt32(cleaned, radix: 16) ?? 0x4C8DF6))
    }
}

/// Type scale, built on the system text styles so it follows the user's text size rather than
/// pinning everything to a point size we happened to like.
enum Typo {
    static let title = Font.system(.body, design: .default).weight(.semibold)
    static let body = Font.system(.body)
    static let bodyEmphasis = Font.system(.body).weight(.medium)
    static let label = Font.system(.callout)
    static let labelEmphasis = Font.system(.callout).weight(.medium)
    static let caption = Font.system(.caption)
    static let captionEmphasis = Font.system(.caption).weight(.medium)
    static let micro = Font.system(.caption2).weight(.medium)

    static let code = Font.system(.callout, design: .monospaced)
    static let codeSmall = Font.system(.caption, design: .monospaced)
    static let codeTiny = Font.system(.caption2, design: .monospaced)
}

enum Metrics {
    static let sidebarWidth: CGFloat = 260
    static let inspectorWidth: CGFloat = 380
    /// Matches the row height AppKit uses for a source list.
    static let rowHeight: CGFloat = 28
    /// Corner radii. Radii only: a gap between two views comes from the spacing scale below, even
    /// where the number happens to match.
    static let corner: CGFloat = 6
    static let cornerSmall: CGFloat = 4

    static let gutter: CGFloat = 12
    /// One physical pixel on the display the window is actually on.
    static var hairline: CGFloat { 1 / (NSScreen.main?.backingScaleFactor ?? 2) }
    /// Clearance for the traffic lights when the title bar is hidden.
    static let titleBarHeight: CGFloat = 28

    // MARK: Spacing
    //
    // One scale for the whole window. These used to be literals at every call site, so the
    // sidebar and the inspector drifted a point or two apart on every row they both draw, and
    // where there was no literal a corner radius was borrowed instead, which tied a gap to a
    // rounding for no reason other than the two numbers happening to match.

    /// Between two things that read as one thing, such as a glyph and its count.
    static let spacingTight: CGFloat = 2
    /// Between a label and the number beside it.
    static let spacingSmall: CGFloat = 4
    /// Between controls in a row.
    static let spacing: CGFloat = 6
    /// Between the groups a row falls into.
    static let spacingWide: CGFloat = 8
    /// What a row keeps from the edge of its pane.
    static let inset: CGFloat = 10
    /// Between the blocks of a full-width pane, such as one project's block on Home.
    static let spacingSection: CGFloat = 20
    /// What a full-width pane of content keeps from the window edge. Larger than `inset`, which
    /// is a row's margin inside a narrow column.
    static let pane: CGFloat = 24

    // MARK: Marks

    /// The project colour marker, in the sidebar, in search results and in the toolbar title.
    /// Small enough to read as a marker rather than as a control.
    static let swatch: CGFloat = 9
    /// The box a sidebar row's state glyph sits in, matching the cap height of the text beside
    /// it so the glyphs line up down the column whichever state each row is in.
    static let glyph: CGFloat = 13
    /// A status dot, sized to sit on a text baseline rather than to be noticed on its own.
    static let dot: CGFloat = 6
    /// A strip of small controls along the edge of a pane: the sidebar's status bar, the
    /// inspector's pull request strip and its tab row.
    static let barHeight: CGFloat = 32
}

// MARK: - Materials

/// A real AppKit material, so the sidebar is translucent and vibrant the way every other Mac
/// sidebar is, and so it dims correctly when the window is not key.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    var emphasized = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
        view.isEmphasized = emphasized
    }
}

extension View {
    func sidebarMaterial() -> some View {
        background(VisualEffectBackground(material: .sidebar))
    }

    func headerMaterial() -> some View {
        background(VisualEffectBackground(material: .headerView, blending: .withinWindow))
    }
}

// MARK: - Reusable chrome

/// A separator that stays one physical pixel on Retina.
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
    var background: Color = Palette.hover
    var monospaced: Bool = false

    @Environment(\.isOnEmphasizedSelection) private var isOnSelection

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2)
                    .imageScale(.small)
            }
            Text(text)
                .font(monospaced ? Typo.codeTiny : Typo.micro)
                .lineLimit(1)
        }
        .foregroundStyle(isOnSelection ? Palette.selectedEmphasizedText : tint)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            isOnSelection ? Palette.selectedEmphasizedText.opacity(0.2) : background,
            in: RoundedRectangle(cornerRadius: Metrics.cornerSmall)
        )
    }
}

/// `+118 -4` as seen next to a workspace in the sidebar.
struct DiffStatLabel: View {
    var additions: Int
    var deletions: Int
    var compact: Bool = false

    @Environment(\.isOnEmphasizedSelection) private var isOnSelection

    var body: some View {
        HStack(spacing: Metrics.spacingSmall) {
            if additions > 0 {
                Text("+\(Self.abbreviate(additions))")
                    .foregroundStyle(isOnSelection ? Palette.selectedEmphasizedText : Palette.positive)
            }
            if deletions > 0 {
                Text("-\(Self.abbreviate(deletions))")
                    .foregroundStyle(
                        isOnSelection
                            ? Palette.selectedEmphasizedText.opacity(0.75)
                            : Palette.negative
                    )
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

/// Whether the content is sitting on an emphasized (accent coloured) selection.
///
/// A selected row inverts its text, but a label that hard-codes a colour, such as a green plus
/// count, keeps its own and ends up unreadable on the accent fill. Descendants read this to pick
/// a variant that survives the inversion, which is what AppKit does for secondary text in a
/// selected table row.
private struct OnEmphasizedSelectionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isOnEmphasizedSelection: Bool {
        get { self[OnEmphasizedSelectionKey.self] }
        set { self[OnEmphasizedSelectionKey.self] = newValue }
    }
}

/// Rows in the sidebar and the file list share this hover and selection treatment.
///
/// Selection follows the AppKit convention rather than a single fixed colour: the accent colour
/// only when the window is active, a quiet grey otherwise. A row that stays vivid blue in a
/// background window is one of the clearest tells that an app is not really native.
struct RowBackground: ViewModifier {
    var isSelected: Bool
    var isHovered: Bool

    @Environment(\.controlActiveState) private var activeState

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: Metrics.corner)
                    .fill(fill)
            }
            .foregroundStyle(isEmphasized ? Palette.selectedEmphasizedText : Palette.textPrimary)
            .environment(\.isOnEmphasizedSelection, isEmphasized)
    }

    private var isEmphasized: Bool {
        isSelected && activeState != .inactive
    }

    private var fill: Color {
        if isSelected {
            return activeState == .inactive ? Palette.selected : Palette.selectedEmphasized
        }
        return isHovered ? Palette.hover : .clear
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
            .fill(isActive ? tint : Palette.textTertiary)
            .frame(width: Metrics.dot, height: Metrics.dot)
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
