import SwiftUI
import BloomCore

/// The four marks a glance has to tell apart, side by side, at the size they are read at.
///
/// It exists because of one report: "a green busy indicator is easily being confused with another
/// green icon status". `Palette.running` was `Palette.positive` was `Palette.accent`, three names
/// for one value, so a passing workspace's tick and a working workspace's dot were the same hue two
/// rows apart and only their shapes said which was which. Nothing in the source showed that. The
/// decision is one `case` in `WorkspaceStatusGlyph.tint` and one `static let` in `Palette`, and
/// what was wrong with it is how four of these look **beside each other** down a 260 point column.
///
/// So this page is that column, and it is the picture the argument was settled with, the way
/// `ActivityRule`'s own note says this codebase settles a colour twice over. It is also the page
/// that catches the next collision: put a fifth meaning colour anywhere near this hue and the four
/// swatches at the foot will say so before a window has to.
///
/// `--snapshot` writes it as `running-colour-<appearance>.png`, which is both appearances and is
/// the whole of "does it work in dark": nothing here is drawn twice on one page, because
/// `Palette`'s pairs resolve against the appearance the render is made in and a page that forced
/// the other half would be photographing a colour the window never shows.
///
/// **Everything on it is held still, deliberately.** The rule's moving figure is a `CALayer` and
/// the dots become layers while the heartbeat runs, and `ImageRenderer` paints SwiftUI's yellow
/// placeholder over an `NSViewRepresentable`, so a page that moved could only be photographed by
/// putting a window in front of whoever is using this Mac. Held still it is exactly what `Reduce
/// Motion` draws, which is a state the colours have to work in anyway. The moving versions are
/// `--snapshot-gallery --gallery running-glyph|activity-rule --running`.
struct RunningColourGallery: View {
    /// The states the report put next to each other, in the order the sidebar had them.
    ///
    /// A running workspace, a passing one, a pending check and a failing one: one from each of the
    /// four meaning colours the column can draw, which is the set a hue has to be told apart from.
    private static let states: [Mark] = [
        Mark(status: .running, name: "Working"),
        Mark(status: .checksPassed, name: "Checks passed"),
        Mark(status: .checksRunning, name: "Checks running"),
        Mark(status: .checksFailing, name: "Checks failing"),
    ]

    /// One row of the four. A named type rather than a tuple, because `ForEach` wants an identity
    /// and a tuple has no key path to give it.
    private struct Mark: Identifiable {
        let status: WorkspaceStatus
        let name: String
        var id: WorkspaceStatus { status }
    }

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Running, against what it sits beside")
                    .font(Typo.title)
                Text("The four marks a glance has to tell apart, and the hues they are drawn in.")
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
            }

            column
            enlarged
            elsewhere
            swatches
        }
        .padding(Metrics.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.surface)
    }

    // MARK: The column the report was made in

    /// The sidebar, at its own width and on its own ground, with the four rows in it.
    ///
    /// The width matters. These marks are told apart down a narrow column at a glance, never in a
    /// row of enlargements, and the whole complaint was about two of them a couple of rows apart.
    private var column: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Down the sidebar, at 260 points")
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
            VStack(spacing: 0) {
                ForEach(Self.states) { mark in
                    HStack(spacing: Metrics.spacing) {
                        WorkspaceStatusGlyph(status: mark.status)
                        Text(mark.name)
                            .font(Typo.body)
                            .foregroundStyle(Palette.textPrimary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(width: Metrics.sidebarWidth, height: 32)
                }
            }
            .background(Palette.sidebar)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    /// The same four at six times, so a hue can be read rather than guessed at.
    private var enlarged: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The same four, six times")
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
            HStack(alignment: .top, spacing: 24) {
                ForEach(Self.states) { mark in
                    VStack(spacing: 6) {
                        WorkspaceStatusGlyph(status: mark.status)
                            .scaleEffect(6, anchor: .center)
                            .frame(width: Metrics.glyph * 6, height: Metrics.glyph * 6)
                            .background(Palette.surfaceSunken)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Text(mark.name)
                            .font(Typo.micro)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
            }
        }
    }

    // MARK: The other two places the window says it

    /// The tab's dot and the tab strip's rule, which are the other two marks the report named, with
    /// a passing tick beside each so the pair can be judged rather than admired on its own.
    private var elsewhere: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("On a tab, and on the rule under the strip")
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
            Text("Held still: what Reduce Motion draws, and the only figure a render can photograph.")
                .font(Typo.micro)
                .foregroundStyle(Palette.textSecondary)

            HStack(spacing: 10) {
                tab { ActivityDot(isActive: true) }
                tab { WorkspaceStatusGlyph(status: .checksPassed) }
                Spacer(minLength: 0)
            }

            ZStack(alignment: .bottom) {
                Palette.sidebar
                Hairline()
                ActivityRuleFigure(variant: .crest, isMoving: false)
            }
            .frame(width: Self.ruleWidth, height: 26)
        }
    }

    /// The centre column at a window somebody would work in, which is the width the rule was tuned
    /// at. `ActivityRuleGallery` uses the same number and for the same reason.
    private static let ruleWidth: CGFloat = 760

    private func tab<Content: View>(@ViewBuilder mark: () -> Content) -> some View {
        HStack(spacing: Metrics.spacingSmall) {
            mark()
            Text("Chat")
                .font(Typo.label)
                .foregroundStyle(Palette.textPrimary)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Palette.surfaceSunken)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: The numbers

    /// Every meaning colour the column can draw, with the hex it resolves to in this appearance.
    ///
    /// The values come from `PaletteInk` rather than from a literal here, so a retune moves the
    /// swatch and the label together and the page cannot claim a colour the window stopped using.
    /// They are worth printing because the failure this page is about was two names resolving to
    /// one number, which a picture shows and a hex proves.
    private var swatches: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The hues, in this appearance")
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
            HStack(spacing: 12) {
                swatch("running", Palette.running, PaletteInk.running)
                swatch("positive", Palette.positive, PaletteInk.accent)
                swatch("warning", Palette.warning, PaletteInk.warning)
                swatch("negative", Palette.negative, PaletteInk.negative)
            }
        }
    }

    private func swatch(_ name: String, _ colour: Color, _ ink: PaletteInk.Pair) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(colour)
                .frame(width: 120, height: 44)
            Text(name)
                .font(Typo.micro)
                .foregroundStyle(Palette.textSecondary)
            Text(Self.hex(ink.member(dark: colorScheme == .dark)))
                .font(Typo.codeTiny)
                .foregroundStyle(Palette.textTertiary)
        }
    }

    /// `#RRGGBB`, built rather than formatted, so this file needs nothing but SwiftUI and the core.
    private static func hex(_ value: UInt32) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return "#" + String(repeating: "0", count: max(0, 6 - digits.count)) + digits
    }
}

extension Gallery {
    /// The registry entry for this page. See `Gallery`.
    ///
    /// Nothing on it moves and nothing on it is typed into, so it asks for neither the heartbeat
    /// nor the keys. Drawn in a window it will pulse, because the dots read the heartbeat rather
    /// than a flag, and that is a fair picture of the window as well.
    static let runningColour = Gallery(
        name: "running-colour",
        title: "Running, against what it sits beside",
        size: CGSize(width: 900, height: 900),
        needsFocus: false,
        view: { _ in AnyView(RunningColourGallery()) }
    )
}
