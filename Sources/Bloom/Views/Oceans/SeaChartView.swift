import SwiftUI
import BloomCore

/// The chart itself: aged paper, an inked coastline, and an X for every discovered sea.
///
/// Drawn in a `Canvas` from the coastline baked into the core, not MapKit: MapKit's three
/// styles are all a satellite era atlas, restyling it means a tile server, and this window
/// works offline. Drawing by hand is also what lets the whole world be on the sheet from the
/// first open, discovered or not, which `SeaChartProjection.mapRect` guarantees by never
/// framing anything smaller.
///
/// Every placement decision here is a call into the core, where it has tests. This view only
/// converts unit points to pixels and holds the ink.
///
/// Nothing animates, so there is nothing for Reduce Motion to reduce: a chart is a still
/// object, and stillness is part of the register.
struct SeaChartView: View {
    /// The seas to mark, in a stable order: placement is greedy, so the caller sorts by
    /// discovery date and the first sea found keeps its name when a neighbour crowds in later.
    let discovered: [Ocean]
    /// Whether to write the empty state's invitation into the southern ocean. False while the
    /// store is still being read, so the words never flash before the facts arrive.
    let showEmptyNotice: Bool

    @Environment(\.colorScheme) private var colorScheme
    /// The one text size on the chart, scaled with the user's setting so the names stay
    /// readable without the map growing with them.
    @ScaledMetric(relativeTo: .caption) private var labelSize = 9.5

    /// Paper kept around the map for the frame and its ticks.
    private static let margin = 30.0
    /// Half the width of a mark's X, which is also the clearance labels keep from marks.
    private static let markRadius = 5.0

    var body: some View {
        let ink = ChartInk.resolve(colorScheme)
        Canvas { context, size in
            drawPaper(context, size: size, ink: ink)
            let rect = mapRect(in: size)
            guard rect.width > 0 else { return }
            drawGraticule(context, in: rect, ink: ink)
            drawLand(context, in: rect, ink: ink)
            drawFrame(context, in: rect, ink: ink)
            drawRose(context, in: rect, ink: ink)
            drawMarks(context, in: rect, ink: ink)
            if showEmptyNotice { drawNotice(context, in: rect, ink: ink) }
        }
        .overlay { tooltips }
        .accessibilityLabel(accessibilitySummary)
    }

    private func mapRect(in size: CGSize) -> CGRect {
        let map = SeaChartProjection.mapRect(
            fittingWidth: size.width, height: size.height, margin: Self.margin
        )
        return CGRect(x: map.x, y: map.y, width: map.width, height: map.height)
    }

    private func point(for ocean: Ocean, in rect: CGRect) -> CGPoint {
        let mark = SeaChartProjection.markPoint(
            latitude: ocean.latitude, longitude: ocean.longitude,
            inX: rect.minX, y: rect.minY, width: rect.width, height: rect.height,
            inset: Self.markRadius + 1
        )
        return CGPoint(x: mark.x, y: mark.y)
    }

    // MARK: Paper

    /// The sheet: one flat tone, a seeded speckle for grain, and a vignette that deepens
    /// towards the edges. The speckle is a fixed sequence, not `random`, because paper does
    /// not regrow its grain every time a window resizes.
    private func drawPaper(_ context: GraphicsContext, size: CGSize, ink: ChartInk) {
        let sheet = CGRect(origin: .zero, size: size)
        context.fill(Path(sheet), with: .color(ink.paper))

        var seed = ChartGrain(seed: 0x5EED)
        for _ in 0..<280 {
            let x = seed.next() * size.width
            let y = seed.next() * size.height
            let radius = 0.4 + seed.next() * 0.9
            let speck = CGRect(x: x, y: y, width: radius, height: radius)
            context.fill(Path(ellipseIn: speck), with: .color(ink.ink.opacity(0.05)))
        }

        context.fill(
            Path(sheet),
            with: .radialGradient(
                Gradient(colors: [.clear, ink.shade.opacity(ink.vignette)]),
                center: CGPoint(x: size.width / 2, y: size.height / 2),
                startRadius: min(size.width, size.height) * 0.35,
                endRadius: hypot(size.width, size.height) / 2
            )
        )
    }

    // MARK: Graticule and frame

    private func drawGraticule(_ context: GraphicsContext, in rect: CGRect, ink: ChartInk) {
        var lines = Path()
        var axes = Path()
        for degrees in stride(from: -150.0, through: 150.0, by: 30.0) {
            let x = rect.minX + (degrees + 180) / 360 * rect.width
            if degrees == 0 {
                axes.move(to: CGPoint(x: x, y: rect.minY))
                axes.addLine(to: CGPoint(x: x, y: rect.maxY))
            } else {
                lines.move(to: CGPoint(x: x, y: rect.minY))
                lines.addLine(to: CGPoint(x: x, y: rect.maxY))
            }
        }
        for degrees in stride(from: -60.0, through: 60.0, by: 30.0) {
            let y = rect.minY + (90 - degrees) / 180 * rect.height
            if degrees == 0 {
                axes.move(to: CGPoint(x: rect.minX, y: y))
                axes.addLine(to: CGPoint(x: rect.maxX, y: y))
            } else {
                lines.move(to: CGPoint(x: rect.minX, y: y))
                lines.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
        }
        context.stroke(lines, with: .color(ink.ink.opacity(0.10)), lineWidth: 0.5)
        // The equator and the prime meridian a shade firmer: the pair gives the eye its
        // bearings without a single number on the sheet.
        context.stroke(axes, with: .color(ink.ink.opacity(0.17)), lineWidth: 0.5)
    }

    /// The neatline: a heavier outer rule, a fine inner one, and a ten degree tick band
    /// between them, which is what a chart wears instead of printed coordinates.
    private func drawFrame(_ context: GraphicsContext, in rect: CGRect, ink: ChartInk) {
        let outer = rect.insetBy(dx: -5, dy: -5)
        context.stroke(Path(outer), with: .color(ink.ink.opacity(0.75)), lineWidth: 1.2)
        context.stroke(Path(rect), with: .color(ink.ink.opacity(0.55)), lineWidth: 0.5)

        var ticks = Path()
        for degrees in stride(from: -170.0, through: 170.0, by: 10.0) {
            let x = rect.minX + (degrees + 180) / 360 * rect.width
            ticks.move(to: CGPoint(x: x, y: rect.minY))
            ticks.addLine(to: CGPoint(x: x, y: outer.minY))
            ticks.move(to: CGPoint(x: x, y: rect.maxY))
            ticks.addLine(to: CGPoint(x: x, y: outer.maxY))
        }
        for degrees in stride(from: -80.0, through: 80.0, by: 10.0) {
            let y = rect.minY + (90 - degrees) / 180 * rect.height
            ticks.move(to: CGPoint(x: rect.minX, y: y))
            ticks.addLine(to: CGPoint(x: outer.minX, y: y))
            ticks.move(to: CGPoint(x: rect.maxX, y: y))
            ticks.addLine(to: CGPoint(x: outer.maxX, y: y))
        }
        context.stroke(ticks, with: .color(ink.ink.opacity(0.45)), lineWidth: 0.5)
    }

    // MARK: Land

    /// The coast is stroked twice: a wide faint pass first, then the fill, then the fine line.
    /// The fill covers the inner half of the wide pass, so what survives is a soft wash on the
    /// water side of every shore, which is how engravers shaded a coast. Islands smaller than
    /// the wash is wide are left out of the first pass: an islet a few pixels across has no
    /// inside for the fill to keep, so the whole wash survived and drew a starburst where
    /// Hawaii should be a speck.
    private func drawLand(_ context: GraphicsContext, in rect: CGRect, ink: ChartInk) {
        var path = Path()
        var washed = Path()
        for ring in SeaChartCoast.rings {
            guard let first = ring.first else { continue }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            var subpath = Path()
            subpath.move(to: CGPoint(
                x: rect.minX + first.x * rect.width, y: rect.minY + first.y * rect.height
            ))
            for point in ring.dropFirst() {
                minX = min(minX, point.x); maxX = max(maxX, point.x)
                minY = min(minY, point.y); maxY = max(maxY, point.y)
                subpath.addLine(to: CGPoint(
                    x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height
                ))
            }
            subpath.closeSubpath()
            path.addPath(subpath)
            if max((maxX - minX) * rect.width, (maxY - minY) * rect.height) > 7 {
                washed.addPath(subpath)
            }
        }
        context.stroke(
            washed, with: .color(ink.ink.opacity(0.10)),
            style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
        )
        context.fill(path, with: .color(ink.land), style: FillStyle(eoFill: true))
        context.stroke(
            path, with: .color(ink.ink.opacity(0.8)),
            style: StrokeStyle(lineWidth: 0.8, lineJoin: .round)
        )
    }

    // MARK: Compass rose

    /// A small eight point rose in the south Pacific, the emptiest water on the sheet. One
    /// ornament, kept quiet: the marks are the point of the chart, and every flourish beside
    /// them makes an X harder to find.
    private func drawRose(_ context: GraphicsContext, in rect: CGRect, ink: ChartInk) {
        let centre = CGPoint(x: rect.minX + 0.155 * rect.width, y: rect.minY + 0.64 * rect.height)
        let radius = min(24, rect.height * 0.075)
        guard radius > 10 else { return }

        let ring = CGRect(
            x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2
        )
        context.stroke(Path(ellipseIn: ring), with: .color(ink.ink.opacity(0.4)), lineWidth: 0.5)
        context.stroke(
            Path(ellipseIn: ring.insetBy(dx: radius * 0.28, dy: radius * 0.28)),
            with: .color(ink.ink.opacity(0.3)), lineWidth: 0.5
        )

        for eighth in 0..<8 {
            let cardinal = eighth % 2 == 0
            let angle = Double(eighth) * .pi / 4 - .pi / 2
            let length = cardinal ? radius : radius * 0.55
            let halfWidth = radius * (cardinal ? 0.14 : 0.09)
            let tip = CGPoint(x: centre.x + cos(angle) * length, y: centre.y + sin(angle) * length)
            let left = CGPoint(
                x: centre.x + cos(angle - .pi / 2) * halfWidth,
                y: centre.y + sin(angle - .pi / 2) * halfWidth
            )
            let right = CGPoint(
                x: centre.x + cos(angle + .pi / 2) * halfWidth,
                y: centre.y + sin(angle + .pi / 2) * halfWidth
            )
            var ray = Path()
            ray.move(to: tip)
            ray.addLine(to: left)
            ray.addLine(to: right)
            ray.closeSubpath()
            context.fill(ray, with: .color(ink.ink.opacity(cardinal ? 0.55 : 0.32)))
        }

        var north = context.resolve(
            Text("N").font(.system(size: 7.5, weight: .medium, design: .serif))
        )
        north.shading = .color(ink.ink.opacity(0.6))
        context.draw(north, at: CGPoint(x: centre.x, y: centre.y - radius - 6))
    }

    // MARK: Marks and names

    private func drawMarks(_ context: GraphicsContext, in rect: CGRect, ink: ChartInk) {
        let positions = discovered.map { point(for: $0, in: rect) }
        for (index, position) in positions.enumerated() {
            drawX(context, at: position, slug: discovered[index].slug, ink: ink)
        }

        let font = Font.system(size: labelSize, weight: .medium, design: .serif)
            .lowercaseSmallCaps()
        let texts = discovered.map { ocean in
            var text = context.resolve(Text(ocean.name).font(font))
            text.shading = .color(ink.label)
            return text
        }
        let room = CGSize(width: rect.width, height: rect.height)
        let sizes = texts.map { text in
            let measured = text.measure(in: room)
            return (width: Double(measured.width), height: Double(measured.height))
        }
        let labels = SeaChartLabels.place(
            marks: positions.map { (x: $0.x, y: $0.y) },
            sizes: sizes,
            markRadius: Self.markRadius,
            boundsX: rect.minX, boundsY: rect.minY,
            boundsWidth: rect.width, boundsHeight: rect.height
        )
        for label in labels {
            let box = CGRect(x: label.x, y: label.y, width: label.width, height: label.height)
            // A wash of paper under the name, so it stays readable across a coastline or a
            // neighbour's shading without wearing a chip's border.
            context.fill(
                Path(roundedRect: box.insetBy(dx: -2, dy: -0.5), cornerRadius: 2),
                with: .color(ink.paper.opacity(0.65))
            )
            context.draw(texts[label.mark], in: box)
        }
    }

    /// Two strokes, each a shallow curve, crossing at a slightly irregular angle seeded from
    /// the slug: the same sea always draws the same X, and no two seas draw quite the same
    /// one, which is what a hand does.
    private func drawX(_ context: GraphicsContext, at centre: CGPoint, slug: String, ink: ChartInk) {
        var grain = ChartGrain(seed: slug.utf8.reduce(UInt64(0x811C_9DC5)) { ($0 ^ UInt64($1)) &* 0x0100_0000_01B3 })
        let radius = Self.markRadius - 0.6
        for arm in 0..<2 {
            let angle = (arm == 0 ? 1.0 : -1.0) * (.pi / 4) + (grain.next() - 0.5) * 0.3
            let from = CGPoint(x: centre.x - cos(angle) * radius, y: centre.y - sin(angle) * radius)
            let to = CGPoint(x: centre.x + cos(angle) * radius, y: centre.y + sin(angle) * radius)
            let bow = (grain.next() - 0.5) * 2.4
            let control = CGPoint(
                x: centre.x + cos(angle + .pi / 2) * bow, y: centre.y + sin(angle + .pi / 2) * bow
            )
            var stroke = Path()
            stroke.move(to: from)
            stroke.addQuadCurve(to: to, control: control)
            context.stroke(
                stroke, with: .color(ink.mark),
                style: StrokeStyle(lineWidth: 1.6, lineCap: .round)
            )
        }
    }

    // MARK: Empty state

    /// The invitation, written into the southern ocean where the sheet is all water. Quieter
    /// than the panel it replaces, because a chart full of unnamed sea is already the message.
    private func drawNotice(_ context: GraphicsContext, in rect: CGRect, ink: ChartInk) {
        let centre = CGPoint(x: rect.midX, y: rect.minY + 0.76 * rect.height)
        var headline = context.resolve(
            Text("No seas discovered yet")
                .font(.system(size: 13, weight: .medium, design: .serif).lowercaseSmallCaps())
                .kerning(1.4)
        )
        headline.shading = .color(ink.ink.opacity(0.75))
        context.draw(headline, at: centre)

        var invitation = context.resolve(
            Text("Create a workspace and the first will be charted here")
                .font(.system(size: 10, design: .serif).italic())
        )
        invitation.shading = .color(ink.ink.opacity(0.5))
        context.draw(invitation, at: CGPoint(x: centre.x, y: centre.y + 16))
    }

    // MARK: Tooltips and accessibility

    /// A hit target over every X, because the labels are allowed to lose: a cluster too tight
    /// to name still answers to the pointer, and to VoiceOver, one sea at a time.
    private var tooltips: some View {
        GeometryReader { geometry in
            let rect = mapRect(in: geometry.size)
            if rect.width > 0 {
                ForEach(discovered) { ocean in
                    Color.clear
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                        .help(ocean.name)
                        .accessibilityLabel(ocean.name)
                        .position(point(for: ocean, in: rect))
                }
            }
        }
    }

    private var accessibilitySummary: String {
        switch discovered.count {
        case 0: "Chart of the world, no seas discovered yet"
        case 1: "Chart of the world, 1 sea discovered"
        default: "Chart of the world, \(discovered.count) seas discovered"
        }
    }
}

/// The chart's two inks, resolved by hand rather than through `Palette`: parchment belongs to
/// this one window, and the dark sheet is a deliberate second design, not an inversion. Dark
/// is the same chart read by lamplight: the paper goes to a deep warm umber instead of
/// Bloom's blue, because blue under parchment ink reads as a different, colder object, and
/// the ink and the marks lighten to keep the same contrast the light sheet has.
private struct ChartInk {
    let paper: Color
    let land: Color
    let ink: Color
    let mark: Color
    let label: Color
    let shade: Color
    let vignette: Double

    static func resolve(_ scheme: ColorScheme) -> ChartInk {
        scheme == .dark
            ? ChartInk(
                paper: chartColor(0x241C11),
                land: chartColor(0x2E2515),
                ink: chartColor(0xC2AC7C),
                mark: chartColor(0xD9704F),
                label: chartColor(0xD3BE8D),
                shade: chartColor(0x000000),
                vignette: 0.34
            )
            : ChartInk(
                paper: chartColor(0xEAE0C2),
                land: chartColor(0xDFD2AA),
                ink: chartColor(0x52402A),
                mark: chartColor(0x9E3826),
                label: chartColor(0x46351F),
                shade: chartColor(0x6B5228),
                vignette: 0.13
            )
    }
}

private func chartColor(_ rgb: UInt32) -> Color {
    Color(
        red: Double((rgb >> 16) & 0xFF) / 255,
        green: Double((rgb >> 8) & 0xFF) / 255,
        blue: Double(rgb & 0xFF) / 255
    )
}

/// A small fixed sequence for grain and jitter. Not `SystemRandomNumberGenerator`, because
/// the paper must not re-speckle on every redraw, and not `srand48`, because two windows
/// would share its global state. SplitMix64, which is four lines and passes for paper.
private struct ChartGrain {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }
}
