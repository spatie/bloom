import SwiftUI
import BloomCore

/// Every mark a glance has to tell the busy one from, side by side, at the size they are read at.
///
/// It exists because of one report: "a green busy indicator is easily being confused with another
/// green icon status". `Palette.running` was `Palette.positive` was `Palette.accent`, three names
/// for one value, so a passing workspace's tick and a working workspace's dot were the same hue two
/// rows apart and only their shapes said which was which. Nothing in the source showed that. The
/// decision is one `case` in `WorkspaceStatusGlyph.tint` and one `static let` in `Palette`, and
/// what was wrong with it is how these look **beside each other** down a 260 point column.
///
/// So this page is that column, and it is the picture the argument was settled with, the way
/// `ActivityRule`'s own note says this codebase settles a colour twice over.
///
/// **The page grew when the mark went blue, and what it grew is the point of it.** The first answer
/// to that report was orange, which had no near neighbour in this palette at all, and four rows was
/// the whole question. The owner asked for the house blue instead, and a blue lands between three
/// things: `positive`, which is a teal-green; `merged`, which is GitHub violet; and the tertiary
/// ink, which in dark is a blue-grey at hue 198. A quiet workspace and a working one going the same
/// colour is the same defect as the one being fixed, so the grey states are on the page now, and so
/// is the violet. See `Palette.running` for the measurements; this is them, drawn.
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
    /// One from each colour the column can draw, which is the set a hue has to be told apart from:
    /// the running mark, the accent, amber, red, GitHub violet, and a grey. The last two are here
    /// because the mark is blue: violet is the nearest hue the palette owns, and a grey state is
    /// what a blue that drifted toward the tertiary ink would be mistaken for, which would say a
    /// workspace has nothing happening in it at exactly the moment it does.
    ///
    /// `clean` rather than `draft` or `closed` for the grey, because it is the state a working
    /// workspace most often was a minute ago and will be again, so the two really are read in the
    /// same place. `unread` carries the accent as well and is left off: `RunningGlyphGallery` is
    /// the page for that pair, and it has been since the mark was a dot at all.
    private static let states: [Mark] = [
        Mark(status: .running, name: "Working"),
        Mark(status: .checksPassed, name: "Checks passed"),
        Mark(status: .checksRunning, name: "Checks running"),
        Mark(status: .checksFailing, name: "Checks failing"),
        Mark(status: .merged, name: "Merged"),
        Mark(status: .clean, name: "No changes"),
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
                Text("What the busy mark has to be told from, and the hues they are drawn in.")
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

    /// The same set at six times, so a hue can be read rather than guessed at.
    private var enlarged: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The same marks, six times")
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

    // MARK: The other place the window says it

    /// Busy tabs on the strip, beside a tab wearing a passing tick so the pair can be judged rather
    /// than admired on its own, and the column's segment with no strip.
    ///
    /// The report named a dot on the tab and a rule under the strip. Neither is drawn any more, nor
    /// the crest and the shimmer that followed: a band sweeps through a busy tab's capsule and a
    /// segment along a column's top edge (`BusySweep`). So the rows are the sweep at one point in
    /// its crossing, on the selected capsule and on a background tab's wash, then what Reduce Motion
    /// draws in each place instead.
    private var elsewhere: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("On busy tabs, and along a column with no strip")
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
            Text("Held still: one frame of the sweep, then what Reduce Motion draws.")
                .font(Typo.micro)
                .foregroundStyle(Palette.textSecondary)

            ForEach([false, true], id: \.self) { isStill in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 0) {
                        tab(isSelected: true, isBusy: true, isStill: isStill) {
                            Image(systemName: PaneGlyph.chat).font(Typo.caption)
                        }
                        tab(isSelected: false, isBusy: true, isStill: isStill) {
                            Image(systemName: PaneGlyph.chat).font(Typo.caption)
                        }
                        tab(isSelected: false, isBusy: false, isStill: isStill) {
                            WorkspaceStatusGlyph(status: .checksPassed)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 4)
                    .frame(width: Self.columnWidth, height: 32)
                    .background(Palette.sidebar)

                    ZStack(alignment: .top) {
                        Palette.windowBackground
                        if isStill {
                            LinearGradient(
                                colors: [Palette.busyColumnStill, Palette.busyColumnStill.opacity(0)],
                                startPoint: .top, endPoint: .bottom
                            )
                            .frame(height: BusySweep.columnStillHeight)
                        } else {
                            BusySweepStill(figure: .column, width: Self.columnWidth, progress: 0.45)
                                .frame(height: BusySweep.columnThickness)
                        }
                    }
                    .frame(width: Self.columnWidth, height: 44)

                    Text(isStill ? "Reduce Motion" : "Working, 45 per cent through a crossing")
                        .font(Typo.micro)
                        .foregroundStyle(Palette.textTertiary)
                }
            }
        }
    }

    /// The centre column at a window somebody would work in. `ActivityRuleGallery` uses the same
    /// number and for the same reason.
    private static let columnWidth: CGFloat = 760
    /// One tab of a strip at that width, which is `TabItemView`'s widest.
    private static let tabWidth: CGFloat = 160

    private func tab<Content: View>(
        isSelected: Bool, isBusy: Bool, isStill: Bool, @ViewBuilder mark: () -> Content
    ) -> some View {
        HStack(spacing: 6) {
            mark()
            Text("Chat")
                .font(Typo.caption)
                .foregroundStyle(Palette.textPrimary)
        }
        .frame(width: Self.tabWidth, height: TabItemView.tabHeight)
        .background {
            ZStack {
                if isSelected {
                    Capsule().fill(Palette.surface)
                    if isBusy && isStill { Capsule().fill(Palette.busyTabStill) }
                } else if isBusy {
                    Capsule().fill(Palette.busyTabWash)
                }
                if isBusy && !isStill {
                    BusySweepStill(figure: .tab, width: Self.tabWidth, progress: 0.45)
                        .clipShape(Capsule())
                }
            }
        }
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
                swatch("merged", Palette.merged, PaletteInk.merged)
                swatch("textTertiary", Palette.textTertiary, PaletteInk.textTertiary)
                swatch("accentFill", Palette.accentFill, PaletteInk.accentFill)
            }
        }
    }

    private func swatch(_ name: String, _ colour: Color, _ ink: PaletteInk.Pair) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(colour)
                .frame(width: 96, height: 44)
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
        size: CGSize(width: 900, height: 1100),
        needsFocus: false,
        view: { _ in AnyView(RunningColourGallery()) }
    )
}
