import SwiftUI
import AppKit

/// Bloom's colours.
///
/// Two kinds of colour live here, and the split is the whole design.
///
/// **Ink, selection and meaning stay semantic.** Text, the focus ring, the caret, the accent and
/// the system reds and greens all resolve to an AppKit semantic colour, because those already
/// track the user's accent choice, Increase Contrast, Differentiate Without Colour and the
/// keyboard access setting. Hard-coding them is what made the first version of this app look like
/// a web page pretending to be a Mac.
///
/// **Ground is Bloom's own.** The five surfaces and the rule between them are named colours, not
/// `windowBackgroundColor` and friends. On macOS 26 every one of those semantic grounds resolves
/// to the same value: window, text and control backgrounds are all pure white in light and all
/// `#1E1E1E` in dark. An app built on them has exactly one surface wearing five names, so nothing
/// separates from anything and the only thing left to divide a pane from its neighbour is a
/// separator at ten percent ink, which on white is very nearly nothing at all. That is the
/// "everything is white and it feels heavy" complaint, stated in numbers.
///
/// The ramp below is a small, deliberate set instead: a body, a panel one step off it, a sidebar
/// one step the other way, and a raised control. In light they carry a slight cool cast so the
/// greys read as one family rather than as camera noise. In dark they are a deep blue rather than
/// a neutral charcoal, which is the appearance this app was designed in and the reason its dark
/// mode does not read as an unlit light mode.
///
/// Every value is a step of a single ramp, so the relationships hold: body to panel is small,
/// body to sidebar is small, and the rule carries the actual separation. Adding a sixth surface
/// is how this gets heavy again, so do not.
enum Palette {
    // MARK: Surfaces
    //
    // Four values and one rule. Measured light: FFFFFF / F7FAFA / F1F5F6 / FFFFFF, rule D6E0E4.
    // Measured dark: 0A1A25 / 0C1E2A / 0E202D / 16303F, rule 1E3F53.

    /// The ground the centre column stands on: the transcript, Home, Search, Settings.
    ///
    /// Identical to `surface` on purpose. They are two names for the reading ground because the
    /// call sites mean different things by them, not because the colour differs; if they ever
    /// diverge the window has grown a surface it does not need.
    static let windowBackground = dynamic(light: 0xFFFFFF, dark: 0x0A1A25)

    /// The chrome: the sidebar column, the title bar, and every strip of small controls.
    ///
    /// One value for all of them, which is what macOS itself does. A unified toolbar and a sidebar
    /// are the same material on a real Mac window, and giving each strip a step of its own is how
    /// a window ends up with seven grounds and no shape.
    ///
    /// A named colour rather than a translucent material. A material samples the desktop, so the
    /// sidebar's colour is whatever wallpaper is behind the window: measured on this machine it
    /// came out `#232833` in dark, a blue nobody chose, and it moves when the wallpaper does. A
    /// themed ramp cannot survive that.
    static let sidebar = Color(nsColor: sidebarNSColor)

    /// The same colour as an `NSColor`, because the window's own background is set in AppKit and
    /// has to keep tracking the appearance after it is set. See `WindowChrome`.
    static let sidebarNSColor = dynamicNSColor(light: 0xF1F5F6, dark: 0x0E202D)

    /// Content areas: the transcript, the inspector, anything holding text.
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x0A1A25)

    /// A raised control: a segmented control's selected cell, a bordered button, a browser chip.
    static let surfaceRaised = dynamic(light: 0xFFFFFF, dark: 0x16303F)

    /// A recessed strip: gutters, hunk headers, tool detail blocks, the composer box, the panel.
    ///
    /// The step off `surface` is deliberately small, five units at most. It reads as recessed
    /// because it has a rule under it, not because it is a different colour, which is what keeps
    /// a window holding a dozen of these from looking like a stack of cards.
    static let surfaceSunken = dynamic(light: 0xF7FAFA, dark: 0x0C1E2A)

    // MARK: Overlays
    //
    // These are neutral tints painted over whatever is underneath, so they are expressed as an
    // opacity on the primary label colour rather than as a colour of their own. Writing them as
    // 0xRRGGBBAA was the original bug behind the solid black selection bar: 0x00000014 is the
    // number 20, indistinguishable from an opaque dark blue, so the alpha was never applied.

    /// Measured off the mockup: four percent ink in light, five and a half in dark. It was six in
    /// both, and six percent black on white is a visibly grey slab under the pointer where the
    /// same figure in dark is barely a lift.
    static let hover = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.055)
            : NSColor(white: 0, alpha: 0.04)
    })

    /// A selected row in a list that is not the key window's focus.
    ///
    /// Named rather than `unemphasizedSelectedContentBackgroundColor`, which is a neutral grey:
    /// `#DCDCDC` on the light ramp and `#464646` on the dark one. On the deep blue ground that
    /// grey is the one thing in the window with no blue in it at all, so a resting selection read
    /// as a smudge. These are the same two steps, taken along Bloom's ramp instead.
    static let selected = dynamic(light: 0xDCE7EA, dark: 0x1D4054)
    /// Selection in a focused list inside the key window, where macOS uses the accent colour.
    static let selectedEmphasized = Color(nsColor: .selectedContentBackgroundColor)
    static let selectedEmphasizedText = Color(nsColor: .alternateSelectedControlTextColor)

    // MARK: Lines

    /// The rule between two panes, and under every strip.
    ///
    /// `separatorColor` is ten percent ink, which composites to `#E6E6E6` on white: a 25 unit step
    /// that the eye reads as nothing, drawn at half a point. That is why the window used to have
    /// no edges. This is a 40 unit step in light and a 30 unit step in dark, and `Metrics.hairline`
    /// draws it at a full point, which is what AppKit's own split view divider has always been.
    static let border = dynamic(light: 0xD6E0E4, dark: 0x1E3F53)

    /// The same rule where it has to be noticed: a card under the pointer, a focused boundary.
    static let borderStrong = dynamic(light: 0xBCCDD4, dark: 0x2C5872)

    // MARK: Text

    static let textPrimary = Color(nsColor: .labelColor)
    static let textSecondary = Color(nsColor: .secondaryLabelColor)
    /// Named rather than `tertiaryLabelColor`.
    ///
    /// The system's third rung is 26 percent ink, which is `#BDBDBD` on white: a contrast ratio of
    /// 1.9 to 1, below anything readable, and it is used sixty times in this app for content that
    /// is meant to be read rather than ignored. The system means it for a disabled control. This
    /// is the rung the interface actually wanted, measured off the mockup and sitting between the
    /// system's second and third.
    static let textTertiary = dynamic(light: 0x8A9AA2, dark: 0x62808E)

    /// The system's third rung, kept for the one thing it is right for: something switched off.
    static let textDisabled = Color(nsColor: .tertiaryLabelColor)
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

    /// The stop control, which is a quieter red than a failure is.
    ///
    /// `systemRed` is right for something that went wrong. The stop button is not a failure: it sits
    /// in the composer for the whole length of a turn, and at full saturation it reads as an alarm
    /// about work that is going perfectly well. This keeps the meaning and drops the volume.
    static let stop = Color(nsColor: .systemRed.blended(withFraction: 0.28, of: .secondaryLabelColor) ?? .systemRed)
    static let warning = Color(nsColor: .systemOrange)
    static let running = Color(nsColor: .controlAccentColor)

    // MARK: Diffs
    //
    // Tinted backgrounds, kept low in saturation so a wall of them is still readable, and
    // defined per appearance because a light green that works on white is invisible on charcoal.

    static let diffAddBackground = dynamic(light: 0xE4F3EA, dark: 0x0F322C)
    static let diffAddEmphasis = dynamic(light: 0xB7E3C4, dark: 0x17503B)
    static let diffDeleteBackground = dynamic(light: 0xFBE9E7, dark: 0x2C2029)
    static let diffDeleteEmphasis = dynamic(light: 0xF5C6C6, dark: 0x4F252D)
    /// The line number column, which is the sunken step and nothing else.
    static let diffGutter = surfaceSunken

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
        Color(nsColor: dynamicNSColor(light: light, dark: dark))
    }

    /// The same thing as an `NSColor`, for the handful of places that talk to AppKit directly.
    static func dynamicNSColor(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light)
        }
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
///
/// The rungs are `ScaledFont` rather than `Font` so that a subtree can be set larger without every
/// call site being rewritten; see that type for why macOS forces the question. Outside a
/// conversation the scale is one and each rung resolves to the same `Font` it always was.
///
/// Five rungs, and every name lands on one of them: 15 / 13 / 12 / 11 / 10, where 15 only ever
/// appears inside prose. There used to be three, because on macOS `.caption`, `.caption2` and
/// `.footnote` all resolve to 10 points: `caption` and `micro` were one size wearing two names,
/// `codeSmall` and `codeTiny` likewise, `title` was a hand-rolled `.headline`, and 11, the one
/// step the app actually wanted, was never used at all. `.subheadline` is that step, and it is
/// where everything that sat at 10 for want of anywhere else has moved to.
enum Typo {
    /// 15. The only rung above reading size, and only for a heading inside agent prose, where a
    /// heading set at body size with a weight on it is not a heading, it is a bold sentence.
    static let heading = ScaledFont(.title3, weight: .bold)
    /// 13 bold. `.headline` is the system's own heading style at reading size, so saying so lets
    /// macOS treat it as a heading rather than as body with a weight bolted on.
    static let title = ScaledFont(.headline)
    /// 13. Reading size: prose, and anything the user is meant to read rather than scan.
    static let body = ScaledFont(.body)
    static let bodyEmphasis = ScaledFont(.body, weight: .medium)
    /// 12. The workhorse: row labels, controls, anything scanned rather than read.
    static let label = ScaledFont(.callout)
    static let labelEmphasis = ScaledFont(.callout, weight: .medium)
    /// 11. Supporting text that still has to be legible: a hint under a field, a link out of a
    /// block, the name on a chip.
    static let caption = ScaledFont(.subheadline)
    static let captionEmphasis = ScaledFont(.subheadline, weight: .medium)
    /// 10, the floor, and the reason it is medium rather than regular. Only for something that is
    /// read off the thing beside it: a count, a duration, a unit.
    static let micro = ScaledFont(.footnote, weight: .medium)

    /// The same rungs in monospace, for anything whose columns have to line up: code, a path, a
    /// diff stat. They step with their proportional twins so a filename set beside a label does
    /// not read as a size apart from it.
    static let code = ScaledFont(.callout, design: .monospaced)
    static let codeSmall = ScaledFont(.subheadline, design: .monospaced)
    static let codeTiny = ScaledFont(.footnote, design: .monospaced)
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
    /// One point, which on Retina is two physical pixels.
    ///
    /// It was one physical pixel, which is an iOS and web idea rather than a Mac one: AppKit's own
    /// split view divider, the rule under a table header and the line under a toolbar are all a
    /// full point. At half a point, drawn in a separator colour that is already only a 25 unit
    /// step, the rules in this window were not so much subtle as absent, and every pane floated.
    /// The name stays because a one point rule is still what everyone calls a hairline.
    static let hairline: CGFloat = 1
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

    /// The project's mark: `RepoIcon`, in the sidebar header, on Home, in search results and in
    /// the toolbar title. It was a 9 point dot, which is the size of a bullet and could only ever
    /// carry a colour; at source list icon size it carries the project's initials as well.
    static let repoIcon: CGFloat = 16
    /// The same mark set inline in a line of caption text, where the full size outweighs the
    /// words beside it.
    static let repoIconSmall: CGFloat = 13
    /// The box a sidebar row's state glyph sits in, matching the cap height of the text beside
    /// it so the glyphs line up down the column whichever state each row is in.
    static let glyph: CGFloat = 13
    /// A status dot, sized to sit on a text baseline rather than to be noticed on its own.
    static let dot: CGFloat = 6
    /// What a `Chip` keeps inside its fill. Named because the transcript footer draws a two colour
    /// chip by hand next to a real one, and the two have to be the same shape.
    static let chipInsetH: CGFloat = 5
    static let chipInsetV: CGFloat = 2
    /// A strip of small controls along the edge of a pane: the sidebar's status bar, the
    /// inspector's pull request strip and its tab row.
    static let barHeight: CGFloat = 32
}

/// How a pane arrives and leaves.
///
/// One curve for the inspector and for the terminal panel, because two panes that move at
/// different speeds read as two apps. Short and without overshoot: a pane is furniture, and
/// furniture that springs is a toy. Call sites drop it for Reduce Motion rather than substituting
/// a slower one, because the setting is about movement, not about speed.
enum Motion {
    static let pane: Animation = .easeOut(duration: 0.18)
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
    /// The sidebar's ground.
    ///
    /// A named colour rather than `NSVisualEffectView(.sidebar)`, and this is the one place where
    /// dropping a system material is the right call. Sidebar vibrancy blends with the desktop
    /// behind the window, so the column's colour is set by whatever wallpaper the user happens to
    /// have: measured on this machine it rendered `#232833` in dark, a blue nobody picked, and it
    /// would render green over a green wallpaper. A themed ramp cannot survive that. Everything
    /// vibrancy was buying beyond the tint, the rounded window corner and the toolbar unification,
    /// belongs to the window rather than to this view and is unaffected.
    func sidebarMaterial() -> some View {
        background(Palette.sidebar)
    }

    /// The ground under a strip of small controls: a panel's tab bar, a run script's header.
    ///
    /// `NSVisualEffectView(.headerView)` measured `#292C33` over a `#0A1A25` pane, a neutral grey
    /// with nothing to do with what was behind it, so every strip in the window read as a piece of
    /// a different app laid on top. The chrome colour is what the material was standing in for.
    func headerMaterial() -> some View {
        background(Palette.sidebar)
    }

    /// The strip a tab bar sits in: the header material with the pane's top edge already on it.
    ///
    /// The rule belongs here, behind the tabs, rather than in an overlay over them. Drawn over the
    /// top it crosses the selected tab as well, which boxes that tab in and leaves the strip
    /// reading as a row of buttons; drawn behind, the selected tab's own opaque fill breaks it, and
    /// that break is what joins the tab to the content below.
    func tabStripMaterial() -> some View {
        background {
            ZStack(alignment: .bottom) {
                Palette.sidebar
                Hairline()
            }
        }
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
        // A chip carries content, not metadata: the file a tool read, the model a session started
        // on. At 10 it was the smallest thing in the window while saying the most, and it was the
        // one place drawing a raw `.caption2` rather than a rung of the scale.
        HStack(spacing: Metrics.spacingSmall) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(Typo.micro)
                    .imageScale(.small)
            }
            Text(text)
                .font(monospaced ? Typo.codeSmall : Typo.caption)
                .lineLimit(1)
        }
        .foregroundStyle(isOnSelection ? Palette.selectedEmphasizedText : tint)
        .padding(.horizontal, Metrics.chipInsetH)
        .padding(.vertical, Metrics.chipInsetV)
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
        // One rung, two designs: `compact` is the monospaced form used inside a chip, where the
        // digits have to line up with a filename set in the same face, not a smaller form. It was
        // written as a size step and never was one, because both styles resolved to 10.
        .font(compact ? Typo.codeSmall : Typo.caption)
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    /// Reduce Motion drops the pulse rather than slowing it, the same way the pane animations do.
    /// The dot still says what it said: it is tinted while something is running and grey when it
    /// is not, so nothing is lost by holding it still.
    private var isPulsing: Bool { isActive && pulse && !reduceMotion }

    var body: some View {
        Circle()
            .fill(isActive ? tint : Palette.textTertiary)
            .frame(width: Metrics.dot, height: Metrics.dot)
            .scaleEffect(isPulsing ? 1.35 : 1)
            .opacity(isPulsing ? 0.5 : 1)
            .animation(
                isActive && !reduceMotion
                    ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                    : .default,
                value: pulse
            )
            .onChange(of: isActive, initial: true) { _, active in
                pulse = active
            }
    }
}
