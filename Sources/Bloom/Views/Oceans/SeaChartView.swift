import SwiftUI
import AppKit
import BloomCore

/// The chart itself: aged parchment, an inked coastline, and an X for every discovered sea.
///
/// Drawn in a `Canvas` from the coastline baked into the core, not MapKit: MapKit's three
/// styles are all a satellite era atlas, restyling it means a tile server, and this window
/// works offline. Drawing by hand is also what lets the whole world be on the sheet from the
/// first open, discovered or not.
///
/// Every placement decision here is a call into the core, where it has tests: the camera, the
/// rectangle the world is drawn into, the size of a name, and which names fit. This view only
/// converts unit points to pixels, holds the ink, and turns a trackpad into a camera.
///
/// Nothing animates on its own, so there is nothing for Reduce Motion to reduce. Zoom follows
/// the fingers frame by frame rather than running an animation, which is the same thing a map
/// does everywhere else and is not motion the user did not ask for.
struct SeaChartView: View {
    /// The seas to mark, in a stable order: placement is greedy, so the caller sorts by
    /// discovery date and the first sea found keeps its name when a neighbour crowds in later.
    let discovered: [Ocean]
    /// Whether to write the empty state's invitation into the cartouche. False while the store
    /// is still being read, so the words never flash before the facts arrive.
    let showEmptyNotice: Bool

    @Environment(\.colorScheme) private var colorScheme
    /// The tile is generated in device pixels, so drawing it takes the screen's scale to put
    /// one of its pixels on one of the screen's. On a one times display the grain simply lands
    /// twice as large, which is what a coarser sheet looks like and not a defect.
    @Environment(\.displayScale) private var displayScale
    /// How far in the chart is looking. All the arithmetic is in the core; this is the handle.
    @State private var camera = SeaChartCamera.whole
    /// Multiplies the size the core asks for, so the user's text setting still moves the names
    /// without the chart growing with them.
    @ScaledMetric(relativeTo: .caption) private var textScale = 1.0

    /// Paper kept around the map for the frame, its ticks and the sheet's torn edge.
    static let margin = 30.0

    var body: some View {
        let ink = ChartInk.resolve(colorScheme)
        GeometryReader { geometry in
            let size = geometry.size
            let sheet = Self.sheetRect(in: size)
            let world = Self.worldRect(sheet: sheet, camera: camera)
            Canvas { context, canvasSize in
                draw(context, size: canvasSize, ink: ink)
            }
            // The names, then the events on top of them. The other order was tried and a scroll
            // that happened to start over a mark did nothing at all, because a SwiftUI view
            // carrying `.help` hit tests and does not forward a scroll wheel to anything behind
            // it. The marks underneath are left as the accessibility elements, which the
            // accessibility tree finds without hit testing, and the pointer's tooltip is served
            // by the event view itself.
            .overlay { markElements(world: world, sheet: sheet) }
            .overlay {
                ChartGestures(
                    camera: $camera, sheet: sheet, world: world,
                    tips: tips(world: world, sheet: sheet)
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
    }

    // MARK: Geometry

    static func sheetRect(in size: CGSize) -> CGRect {
        let map = SeaChartProjection.mapRect(
            fittingWidth: size.width, height: size.height, margin: margin
        )
        return CGRect(x: map.x, y: map.y, width: map.width, height: map.height)
    }

    static func worldRect(sheet: CGRect, camera: SeaChartCamera) -> CGRect {
        let world = SeaChartProjection.worldRect(
            inX: sheet.minX, y: sheet.minY, width: sheet.width, height: sheet.height,
            camera: camera
        )
        return CGRect(x: world.x, y: world.y, width: world.width, height: world.height)
    }

    private func unit(_ x: Double, _ y: Double, in world: CGRect) -> CGPoint {
        CGPoint(x: world.minX + x * world.width, y: world.minY + y * world.height)
    }

    private func point(for ocean: Ocean, in world: CGRect, radius: Double) -> CGPoint {
        let mark = SeaChartProjection.markPoint(
            latitude: ocean.latitude, longitude: ocean.longitude,
            inX: world.minX, y: world.minY, width: world.width, height: world.height,
            inset: radius + 1
        )
        return CGPoint(x: mark.x, y: mark.y)
    }

    /// How big a name is drawn, and with it how big a mark is. Both track the sheet rather than
    /// the window: a taller window does not make a two by one chart any wider, and width is all
    /// the room a name has.
    private func typeSize(sheet: CGRect) -> Double {
        SeaChartLabels.fontSize(forMapWidth: sheet.width) * textScale
    }

    private func markRadius(sheet: CGRect) -> Double {
        min(max(typeSize(sheet: sheet) * 0.55, 5.5), 9)
    }

    /// The ornament printed on the chart fades out as it is zoomed into. A rose and a cartouche
    /// are decoration on a sheet held at arm's length; once the chart is being read for names,
    /// a title panel four times life size is in the way of the thing the zoom was for.
    private func figureOpacity() -> Double {
        let fade = (2.6 - camera.scale) / 1.2
        return min(max(fade, 0), 1)
    }

    // MARK: The sheet

    /// The order is the order the object was made in, and the last three passes are the reason
    /// it was changed. The texture used to go down first and was then buried: the map fills the
    /// sheet with an opaque water tone, so every stain and every fibre survived only in the
    /// margin, and the ocean, which is most of what this window is, stayed a flat swatch. Ink
    /// does not hide the paper it was printed on. So the sheet is inked first and the paper is
    /// laid over all of it, grain, stains, vignette and torn edge together, which is also what
    /// makes a name look printed rather than pasted on.
    private func draw(_ context: GraphicsContext, size: CGSize, ink: ChartInk) {
        let page = CGRect(origin: .zero, size: size)
        context.fill(Path(page), with: .color(ink.paper))

        let sheet = Self.sheetRect(in: size)
        if sheet.width > 0 {
            let world = Self.worldRect(sheet: sheet, camera: camera)
            let figures = figureOpacity()

            var chart = context
            chart.clip(to: Path(sheet))
            chart.fill(Path(sheet), with: .color(ink.water))
            drawRhumbs(chart, in: world, ink: ink, opacity: figures)
            drawGraticule(chart, in: world, ink: ink)
            drawLand(chart, in: world, ink: ink)
            if figures > 0.01 {
                drawRose(chart, in: world, ink: ink, opacity: figures)
                drawCartouche(chart, in: world, ink: ink, opacity: figures)
            }
            drawMarks(chart, in: world, sheet: sheet, ink: ink)
            drawFrame(context, in: sheet, ink: ink)
        }

        drawPaper(context, size: size, ink: ink)
        drawDeckle(context, size: size, ink: ink)
    }

    /// The sheet's surface, laid over the ink: formation and stains from one small field
    /// stretched across the window, then grain from a seamless tile at device resolution, then
    /// the vignette that falls away towards the edges.
    ///
    /// This replaced four hundred and twenty seeded dots and fourteen radial blooms. Those were
    /// the right instinct and the wrong material. A dot is a disc of one tone, so four hundred
    /// of them read as specks scattered on a flat colour rather than as a surface, and a radial
    /// gradient is perfectly round with a perfectly even falloff, which is the one thing a water
    /// stain never is. What the field below has instead is a wobbling edge and a tideline, the
    /// darker rim damp leaves behind as it dries and carries its pigment outwards.
    ///
    /// Both bitmaps are made once for the life of the process, not once a frame and not once a
    /// window: neither depends on the size of anything, which is the point of tiling one and
    /// stretching the other, so a window being dragged larger re-tiles the same pixels.
    private func drawPaper(_ context: GraphicsContext, size: CGSize, ink: ChartInk) {
        let page = CGRect(origin: .zero, size: size)

        var surface = context
        surface.opacity = ink.texture
        surface.draw(
            Image(decorative: ChartPaperTexture.field, scale: 1).interpolation(.high),
            in: page
        )
        surface.fill(
            Path(page),
            with: .tiledImage(
                Image(decorative: ChartPaperTexture.tile, scale: displayScale),
                sourceRect: CGRect(x: 0, y: 0, width: 1, height: 1)
            )
        )

        context.fill(
            Path(page),
            with: .radialGradient(
                Gradient(colors: [.clear, ink.shade.opacity(ink.vignette)]),
                center: CGPoint(x: size.width / 2, y: size.height / 2),
                startRadius: min(size.width, size.height) * 0.32,
                endRadius: hypot(size.width, size.height) / 2
            )
        )
    }

    /// The torn edge. A sheet cut with a knife has a straight edge; one that has been in a chart
    /// locker for two hundred years has not, and the wobble along the window's border is the
    /// cheapest signal that this is an object rather than a background colour.
    private func drawDeckle(_ context: GraphicsContext, size: CGSize, ink: ChartInk) {
        var grain = ChartGrain(seed: 0xDEC1)
        let depth = 7.0
        var band = Path()
        band.addRect(CGRect(origin: .zero, size: size))
        var inner = Path()
        let steps = 46
        var points: [CGPoint] = []
        for step in 0...steps {
            points.append(CGPoint(x: Double(step) / Double(steps) * size.width, y: grain.next() * depth))
        }
        for step in 1...steps {
            points.append(CGPoint(x: size.width - grain.next() * depth, y: Double(step) / Double(steps) * size.height))
        }
        for step in 1...steps {
            points.append(CGPoint(x: size.width - Double(step) / Double(steps) * size.width, y: size.height - grain.next() * depth))
        }
        for step in 1...steps {
            points.append(CGPoint(x: grain.next() * depth, y: size.height - Double(step) / Double(steps) * size.height))
        }
        inner.move(to: points[0])
        for point in points.dropFirst() { inner.addLine(to: point) }
        inner.closeSubpath()
        band.addPath(inner)
        context.fill(band, with: .color(ink.shade.opacity(0.22)), style: FillStyle(eoFill: true))
        context.stroke(inner, with: .color(ink.ink.opacity(0.16)), lineWidth: 0.5)
    }

    // MARK: Rhumb lines, graticule and frame

    /// The wind rose network a portolan chart is covered in: sixteen lines out of each of three
    /// nodes, drawn under the land so a continent covers its own. Faint enough to read as the
    /// paper's texture until the eye goes looking, which is exactly what they were for.
    private func drawRhumbs(
        _ context: GraphicsContext, in world: CGRect, ink: ChartInk, opacity: Double
    ) {
        guard opacity > 0.01 else { return }
        let nodes = [(0.155, 0.62), (0.52, 0.28), (0.70, 0.735)]
        let reach = hypot(world.width, world.height)
        var lines = Path()
        for node in nodes {
            let centre = unit(node.0, node.1, in: world)
            for sixteenth in 0..<16 {
                let angle = Double(sixteenth) * .pi / 8
                lines.move(to: centre)
                lines.addLine(to: CGPoint(
                    x: centre.x + cos(angle) * reach, y: centre.y + sin(angle) * reach
                ))
            }
        }
        context.stroke(lines, with: .color(ink.ink.opacity(0.085 * opacity)), lineWidth: 0.5)
    }

    private func drawGraticule(_ context: GraphicsContext, in world: CGRect, ink: ChartInk) {
        var lines = Path()
        var axes = Path()
        for degrees in stride(from: -150.0, through: 150.0, by: 30.0) {
            let x = world.minX + (degrees + 180) / 360 * world.width
            if degrees == 0 {
                axes.move(to: CGPoint(x: x, y: world.minY))
                axes.addLine(to: CGPoint(x: x, y: world.maxY))
            } else {
                lines.move(to: CGPoint(x: x, y: world.minY))
                lines.addLine(to: CGPoint(x: x, y: world.maxY))
            }
        }
        for degrees in stride(from: -60.0, through: 60.0, by: 30.0) {
            let y = world.minY + (90 - degrees) / 180 * world.height
            if degrees == 0 {
                axes.move(to: CGPoint(x: world.minX, y: y))
                axes.addLine(to: CGPoint(x: world.maxX, y: y))
            } else {
                lines.move(to: CGPoint(x: world.minX, y: y))
                lines.addLine(to: CGPoint(x: world.maxX, y: y))
            }
        }
        context.stroke(lines, with: .color(ink.ink.opacity(0.10)), lineWidth: 0.5)
        // The equator and the prime meridian a shade firmer: the pair gives the eye its
        // bearings without a single number on the sheet.
        context.stroke(axes, with: .color(ink.ink.opacity(0.17)), lineWidth: 0.5)
    }

    /// The neatline: a heavy outer rule, a fine inner one, a ten degree tick band between them,
    /// and a corner flourish at each of the four. Drawn outside the clip, so it always frames
    /// the sheet rather than travelling with the camera: it belongs to the paper, not the world.
    ///
    /// Its weights hold at every zoom, along with every other stroke on the chart, because the
    /// pen that drew them did not get a wider nib when the reader leaned in. Scaled strokes were
    /// tried and a coastline at ten times became a smear.
    private func drawFrame(_ context: GraphicsContext, in rect: CGRect, ink: ChartInk) {
        let outer = rect.insetBy(dx: -9, dy: -9)
        context.stroke(Path(outer), with: .color(ink.ink.opacity(0.8)), lineWidth: 1.4)
        context.stroke(Path(rect), with: .color(ink.ink.opacity(0.6)), lineWidth: 0.6)

        var ticks = Path()
        for degrees in stride(from: -170.0, through: 170.0, by: 10.0) {
            let x = rect.minX + (degrees + 180) / 360 * rect.width
            let long = degrees.truncatingRemainder(dividingBy: 30) == 0
            let depth = long ? 9.0 : 4.5
            ticks.move(to: CGPoint(x: x, y: rect.minY))
            ticks.addLine(to: CGPoint(x: x, y: rect.minY - depth))
            ticks.move(to: CGPoint(x: x, y: rect.maxY))
            ticks.addLine(to: CGPoint(x: x, y: rect.maxY + depth))
        }
        for degrees in stride(from: -80.0, through: 80.0, by: 10.0) {
            let y = rect.minY + (90 - degrees) / 180 * rect.height
            let long = degrees.truncatingRemainder(dividingBy: 30) == 0
            let depth = long ? 9.0 : 4.5
            ticks.move(to: CGPoint(x: rect.minX, y: y))
            ticks.addLine(to: CGPoint(x: rect.minX - depth, y: y))
            ticks.move(to: CGPoint(x: rect.maxX, y: y))
            ticks.addLine(to: CGPoint(x: rect.maxX + depth, y: y))
        }
        context.stroke(ticks, with: .color(ink.ink.opacity(0.5)), lineWidth: 0.5)

        var corners = Path()
        for (cornerX, cornerY, signX, signY) in [
            (outer.minX, outer.minY, 1.0, 1.0), (outer.maxX, outer.minY, -1.0, 1.0),
            (outer.minX, outer.maxY, 1.0, -1.0), (outer.maxX, outer.maxY, -1.0, -1.0),
        ] {
            let arm = 16.0
            corners.move(to: CGPoint(x: cornerX + signX * arm, y: cornerY))
            corners.addQuadCurve(
                to: CGPoint(x: cornerX, y: cornerY + signY * arm),
                control: CGPoint(x: cornerX + signX * 4, y: cornerY + signY * 4)
            )
            corners.move(to: CGPoint(x: cornerX + signX * 5, y: cornerY + signY * 5))
            corners.addLine(to: CGPoint(x: cornerX + signX * 11, y: cornerY + signY * 5))
            corners.move(to: CGPoint(x: cornerX + signX * 5, y: cornerY + signY * 5))
            corners.addLine(to: CGPoint(x: cornerX + signX * 5, y: cornerY + signY * 11))
        }
        context.stroke(corners, with: .color(ink.ink.opacity(0.55)), lineWidth: 0.8)
    }

    // MARK: Land

    /// The coast is stroked twice: a wide faint pass first, then the fill, then the fine line.
    /// The fill covers the inner half of the wide pass, so what survives is a soft wash on the
    /// water side of every shore, which is how engravers shaded a coast. Islands smaller than
    /// the wash is wide are left out of the first pass: an islet a few pixels across has no
    /// inside for the fill to keep, so the whole wash survived and drew a starburst where
    /// Hawaii should be a speck.
    ///
    /// The shoreline itself is inked three times, each pass a fraction of a point off the last.
    /// One clean stroke is a plotter; three that do not quite agree is a nib, and it also hides
    /// the straight segments the baked 110m data shows when the chart is zoomed in.
    private func drawLand(_ context: GraphicsContext, in world: CGRect, ink: ChartInk) {
        var path = Path()
        var washed = Path()
        for ring in SeaChartCoast.rings {
            guard let first = ring.first else { continue }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            var subpath = Path()
            subpath.move(to: CGPoint(
                x: world.minX + first.x * world.width, y: world.minY + first.y * world.height
            ))
            for point in ring.dropFirst() {
                minX = min(minX, point.x); maxX = max(maxX, point.x)
                minY = min(minY, point.y); maxY = max(maxY, point.y)
                subpath.addLine(to: CGPoint(
                    x: world.minX + point.x * world.width, y: world.minY + point.y * world.height
                ))
            }
            subpath.closeSubpath()
            path.addPath(subpath)
            if max((maxX - minX) * world.width, (maxY - minY) * world.height) > 7 {
                washed.addPath(subpath)
            }
        }
        context.stroke(
            washed, with: .color(ink.ink.opacity(0.10)),
            style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round)
        )
        context.fill(path, with: .color(ink.land), style: FillStyle(eoFill: true))
        for (dx, dy, opacity, weight) in [
            (0.0, 0.0, 0.8, 0.9), (0.5, -0.4, 0.28, 0.6), (-0.45, 0.5, 0.22, 0.5),
        ] {
            var pass = context
            pass.translateBy(x: dx, y: dy)
            pass.stroke(
                path, with: .color(ink.ink.opacity(opacity)),
                style: StrokeStyle(lineWidth: weight, lineJoin: .round)
            )
        }
    }

    // MARK: The figures printed on the chart

    /// A sixteen point rose in the east Pacific, the emptiest water on the sheet: a lettered
    /// outer ring, a degree collar, eight long points and eight short, and a fleur de lis for
    /// north because that is the one thing every chart of this kind agrees on.
    private func drawRose(
        _ context: GraphicsContext, in world: CGRect, ink: ChartInk, opacity: Double
    ) {
        let centre = unit(0.155, 0.62, in: world)
        let radius = min(world.width * 0.052, 78)
        guard radius > 12 else { return }
        let line = ink.ink.opacity(0.45 * opacity)

        for scale in [1.0, 0.94, 0.42] {
            let ring = CGRect(
                x: centre.x - radius * scale, y: centre.y - radius * scale,
                width: radius * scale * 2, height: radius * scale * 2
            )
            context.stroke(Path(ellipseIn: ring), with: .color(line), lineWidth: scale > 0.9 ? 0.8 : 0.5)
        }

        var collar = Path()
        for step in 0..<72 {
            let angle = Double(step) * .pi / 36
            let inner = radius * (step % 6 == 0 ? 0.94 : 0.965)
            collar.move(to: CGPoint(x: centre.x + cos(angle) * inner, y: centre.y + sin(angle) * inner))
            collar.addLine(to: CGPoint(x: centre.x + cos(angle) * radius, y: centre.y + sin(angle) * radius))
        }
        context.stroke(collar, with: .color(ink.ink.opacity(0.32 * opacity)), lineWidth: 0.5)

        for sixteenth in 0..<16 {
            let cardinal = sixteenth % 4 == 0
            let major = sixteenth % 2 == 0
            let angle = Double(sixteenth) * .pi / 8 - .pi / 2
            let length = radius * (cardinal ? 0.93 : major ? 0.72 : 0.5)
            let halfWidth = radius * (cardinal ? 0.115 : major ? 0.075 : 0.045)
            let tip = CGPoint(x: centre.x + cos(angle) * length, y: centre.y + sin(angle) * length)
            let left = CGPoint(
                x: centre.x + cos(angle - .pi / 2) * halfWidth,
                y: centre.y + sin(angle - .pi / 2) * halfWidth
            )
            let right = CGPoint(
                x: centre.x + cos(angle + .pi / 2) * halfWidth,
                y: centre.y + sin(angle + .pi / 2) * halfWidth
            )
            // Half of every point inked solid and half left open, which is how a rose reads as
            // a raised star rather than a flat asterisk.
            var solid = Path()
            solid.move(to: tip)
            solid.addLine(to: left)
            solid.addLine(to: centre)
            solid.closeSubpath()
            var open = Path()
            open.move(to: tip)
            open.addLine(to: right)
            open.addLine(to: centre)
            open.closeSubpath()
            context.fill(solid, with: .color(ink.ink.opacity((cardinal ? 0.6 : 0.42) * opacity)))
            context.fill(open, with: .color(ink.ink.opacity((cardinal ? 0.2 : 0.14) * opacity)))
            context.stroke(open, with: .color(ink.ink.opacity(0.35 * opacity)), lineWidth: 0.4)
        }

        // The fleur de lis: a lance up the north point with a lobe to each side and a collar.
        let north = CGPoint(x: centre.x, y: centre.y - radius * 0.93)
        var lily = Path()
        lily.move(to: CGPoint(x: north.x, y: north.y - radius * 0.3))
        lily.addQuadCurve(
            to: CGPoint(x: north.x - radius * 0.1, y: north.y + radius * 0.06),
            control: CGPoint(x: north.x - radius * 0.09, y: north.y - radius * 0.12)
        )
        lily.addQuadCurve(
            to: CGPoint(x: north.x + radius * 0.1, y: north.y + radius * 0.06),
            control: CGPoint(x: north.x, y: north.y - radius * 0.04)
        )
        lily.addQuadCurve(
            to: CGPoint(x: north.x, y: north.y - radius * 0.3),
            control: CGPoint(x: north.x + radius * 0.09, y: north.y - radius * 0.12)
        )
        lily.closeSubpath()
        context.fill(lily, with: .color(ink.mark.opacity(0.75 * opacity)))
        for side in [-1.0, 1.0] {
            var lobe = Path()
            lobe.move(to: CGPoint(x: north.x, y: north.y + radius * 0.02))
            lobe.addQuadCurve(
                to: CGPoint(x: north.x + side * radius * 0.17, y: north.y - radius * 0.14),
                control: CGPoint(x: north.x + side * radius * 0.2, y: north.y + radius * 0.04)
            )
            lobe.addQuadCurve(
                to: CGPoint(x: north.x, y: north.y + radius * 0.02),
                control: CGPoint(x: north.x + side * radius * 0.06, y: north.y - radius * 0.02)
            )
            context.fill(lobe, with: .color(ink.mark.opacity(0.6 * opacity)))
        }

        let letterSize = max(6.5, radius * 0.17)
        for (index, letter) in ["N", "E", "S", "W"].enumerated() {
            let angle = Double(index) * .pi / 2 - .pi / 2
            var text = context.resolve(
                Text(letter).font(.system(size: letterSize, weight: .semibold, design: .serif))
            )
            text.shading = .color(ink.ink.opacity(0.7 * opacity))
            context.draw(text, at: CGPoint(
                x: centre.x + cos(angle) * radius * 1.16,
                y: centre.y + sin(angle) * radius * 1.16
            ))
        }
    }

    /// The cartouche in the south Atlantic: the title panel a chart carries instead of a caption
    /// bar, with volutes scrolled off both ends. It also holds the count, and the invitation
    /// when there is nothing charted yet, so an empty chart says what it needs to say inside the
    /// one frame rather than as loose words floating on the water.
    private func drawCartouche(
        _ context: GraphicsContext, in world: CGRect, ink: ChartInk, opacity: Double
    ) {
        guard let panel = cartouchePanel(in: world) else { return }
        let width = panel.width
        let height = panel.height
        let line = ink.ink.opacity(0.55 * opacity)

        context.fill(
            Path(roundedRect: panel, cornerRadius: height * 0.1),
            with: .color(ink.paper.opacity(0.82 * opacity))
        )
        context.stroke(
            Path(roundedRect: panel, cornerRadius: height * 0.1), with: .color(line), lineWidth: 1.1
        )
        context.stroke(
            Path(roundedRect: panel.insetBy(dx: 3.5, dy: 3.5), cornerRadius: height * 0.08),
            with: .color(ink.ink.opacity(0.3 * opacity)), lineWidth: 0.5
        )

        // The volutes: a spiral scrolled off each end, which is the whole difference between a
        // cartouche and a rectangle.
        for side in [-1.0, 1.0] {
            let anchor = CGPoint(x: side < 0 ? panel.minX : panel.maxX, y: panel.midY)
            var scroll = Path()
            scroll.move(to: CGPoint(x: anchor.x, y: panel.minY + height * 0.18))
            scroll.addQuadCurve(
                to: CGPoint(x: anchor.x + side * height * 0.34, y: anchor.y),
                control: CGPoint(x: anchor.x + side * height * 0.42, y: panel.minY + height * 0.1)
            )
            scroll.addQuadCurve(
                to: CGPoint(x: anchor.x, y: panel.maxY - height * 0.18),
                control: CGPoint(x: anchor.x + side * height * 0.42, y: panel.maxY - height * 0.1)
            )
            context.fill(scroll, with: .color(ink.paper.opacity(0.82 * opacity)))
            context.stroke(scroll, with: .color(line), lineWidth: 1.0)
            context.stroke(
                Path(ellipseIn: CGRect(
                    x: anchor.x + side * height * 0.12 - height * 0.07, y: anchor.y - height * 0.07,
                    width: height * 0.14, height: height * 0.14
                )),
                with: .color(ink.ink.opacity(0.4 * opacity)), lineWidth: 0.7
            )
        }

        var title = context.resolve(
            Text("Discovered Seas")
                .font(.system(size: height * (showEmptyNotice ? 0.2 : 0.24), weight: .semibold, design: .serif).lowercaseSmallCaps())
                .kerning(height * 0.02)
        )
        title.shading = .color(ink.ink.opacity(0.85 * opacity))
        context.draw(title, at: CGPoint(x: panel.midX, y: panel.minY + height * 0.28))

        var rule = Path()
        rule.move(to: CGPoint(x: panel.minX + width * 0.18, y: panel.minY + height * 0.44))
        rule.addLine(to: CGPoint(x: panel.maxX - width * 0.18, y: panel.minY + height * 0.44))
        context.stroke(rule, with: .color(ink.ink.opacity(0.35 * opacity)), lineWidth: 0.6)

        var count = context.resolve(
            Text(showEmptyNotice ? "none charted yet" : countLine)
                .font(.system(size: height * (showEmptyNotice ? 0.14 : 0.16), design: .serif).italic())
        )
        count.shading = .color(ink.ink.opacity(0.6 * opacity))
        context.draw(count, at: CGPoint(x: panel.midX, y: panel.minY + height * (showEmptyNotice ? 0.6 : 0.66)))

        if showEmptyNotice {
            var invitation = context.resolve(
                Text("Start a workspace and the first is charted here")
                    .font(.system(size: height * 0.115, design: .serif))
            )
            invitation.shading = .color(ink.ink.opacity(0.55 * opacity))
            context.draw(invitation, at: CGPoint(x: panel.midX, y: panel.minY + height * 0.8))
        }
    }

    /// The cartouche's panel, which both the drawing and the label placer need to agree on. The
    /// empty state runs to a third line, so it gets a wider and squarer panel: the invitation
    /// was set inside the panel sized for two lines and ran off both ends of it.
    private func cartouchePanel(in world: CGRect) -> CGRect? {
        let width = min(world.width * (showEmptyNotice ? 0.28 : 0.2), showEmptyNotice ? 430 : 320)
        guard width > 90 else { return nil }
        let height = width * (showEmptyNotice ? 0.34 : 0.34)
        let centre = unit(0.405, 0.775, in: world)
        return CGRect(
            x: centre.x - width / 2, y: centre.y - height / 2, width: width, height: height
        )
    }

    private var countLine: String {
        discovered.count == 1 ? "one sea charted" : "\(discovered.count) seas charted"
    }

    // MARK: Marks and names

    /// The boxes on the chart a name may not be written over: the cartouche and the rose, both
    /// of which are painted opaque. They vanish as the chart is zoomed into, and so does their
    /// claim on the paper, which is why the fade drives this as well as the drawing.
    private func reservedBoxes(in world: CGRect) -> [(x: Double, y: Double, width: Double, height: Double)] {
        guard figureOpacity() > 0.4 else { return [] }
        var boxes: [(x: Double, y: Double, width: Double, height: Double)] = []
        if let panel = cartouchePanel(in: world) {
            // Wider than the panel by a volute at each end, which is drawn outside it.
            let volute = panel.height * 0.35
            boxes.append((
                panel.minX - volute, panel.minY, panel.width + volute * 2, panel.height
            ))
        }
        let roseRadius = min(world.width * 0.052, 78)
        if roseRadius > 12 {
            let centre = unit(0.155, 0.62, in: world)
            boxes.append((
                centre.x - roseRadius * 1.25, centre.y - roseRadius * 1.25,
                roseRadius * 2.5, roseRadius * 2.5
            ))
        }
        return boxes
    }

    private func drawMarks(
        _ context: GraphicsContext, in world: CGRect, sheet: CGRect, ink: ChartInk
    ) {
        let radius = markRadius(sheet: sheet)
        let positions = discovered.map { point(for: $0, in: world, radius: radius) }
        for (index, position) in positions.enumerated() {
            drawX(context, at: position, radius: radius, slug: discovered[index].slug, ink: ink)
        }

        let font = Font.system(size: typeSize(sheet: sheet), weight: .semibold, design: .serif)
            .lowercaseSmallCaps()
        let texts = discovered.map { ocean in
            var text = context.resolve(Text(ocean.name).font(font).kerning(0.5))
            text.shading = .color(ink.label)
            return text
        }
        let room = CGSize(width: sheet.width, height: sheet.height)
        let sizes = texts.map { text in
            let measured = text.measure(in: room)
            return (width: Double(measured.width), height: Double(measured.height))
        }
        // The sheet, not the world, is what a name has to fit inside: a name placed on the part
        // of a zoomed world hanging off the paper is a name nobody can read. Handing the placer
        // the visible rectangle is also what gives a crowded region its names back as it is
        // zoomed into, because the crowd spreads and the boxes stop colliding.
        let labels = SeaChartLabels.place(
            marks: positions.map { (x: $0.x, y: $0.y) },
            sizes: sizes,
            markRadius: radius,
            boundsX: sheet.minX, boundsY: sheet.minY,
            boundsWidth: sheet.width, boundsHeight: sheet.height,
            reserved: reservedBoxes(in: world)
        )
        for label in labels {
            let box = CGRect(x: label.x, y: label.y, width: label.width, height: label.height)
            // A wash of paper under the name, so it stays readable across a coastline or a
            // neighbour's shading without wearing a chip's border.
            context.fill(
                Path(roundedRect: box.insetBy(dx: -3, dy: -1), cornerRadius: 2),
                with: .color(ink.paper.opacity(0.72))
            )
            context.draw(texts[label.mark], in: box)
        }
    }

    /// Two strokes, each a shallow curve, crossing at a slightly irregular angle seeded from
    /// the slug: the same sea always draws the same X, and no two seas draw quite the same
    /// one, which is what a hand does.
    private func drawX(
        _ context: GraphicsContext, at centre: CGPoint, radius: Double, slug: String, ink: ChartInk
    ) {
        var grain = ChartGrain(seed: slug.utf8.reduce(UInt64(0x811C_9DC5)) { ($0 ^ UInt64($1)) &* 0x0100_0000_01B3 })
        let arm = radius - 0.6
        for stroke in 0..<2 {
            let angle = (stroke == 0 ? 1.0 : -1.0) * (.pi / 4) + (grain.next() - 0.5) * 0.3
            let from = CGPoint(x: centre.x - cos(angle) * arm, y: centre.y - sin(angle) * arm)
            let to = CGPoint(x: centre.x + cos(angle) * arm, y: centre.y + sin(angle) * arm)
            let bow = (grain.next() - 0.5) * 2.4
            let control = CGPoint(
                x: centre.x + cos(angle + .pi / 2) * bow, y: centre.y + sin(angle + .pi / 2) * bow
            )
            var path = Path()
            path.move(to: from)
            path.addQuadCurve(to: to, control: control)
            context.stroke(
                path, with: .color(ink.mark),
                style: StrokeStyle(lineWidth: max(1.6, radius * 0.28), lineCap: .round)
            )
        }
    }

    // MARK: Tooltips and accessibility

    /// A hit target over every X, because the labels are allowed to lose: a cluster too tight
    /// to name still answers to the pointer, and to VoiceOver, one sea at a time. Only the marks
    /// on the sheet get one, since a zoomed chart leaves most of the world off the paper.
    private func markElements(world: CGRect, sheet: CGRect) -> some View {
        let radius = markRadius(sheet: sheet)
        return ZStack {
            ForEach(discovered) { ocean in
                let position = point(for: ocean, in: world, radius: radius)
                if sheet.contains(position) {
                    Color.clear
                        .frame(width: 18, height: 18)
                        .accessibilityLabel(ocean.name)
                        .position(position)
                }
            }
        }
    }

    /// The pointer's tooltips, as rectangles the event view hangs them on.
    private func tips(world: CGRect, sheet: CGRect) -> [(name: String, rect: CGRect)] {
        let radius = markRadius(sheet: sheet)
        return discovered.compactMap { ocean in
            let position = point(for: ocean, in: world, radius: radius)
            guard sheet.contains(position) else { return nil }
            return (
                ocean.name,
                CGRect(x: position.x - 9, y: position.y - 9, width: 18, height: 18)
            )
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

/// The trackpad, turned into a camera.
///
/// An `NSView` rather than SwiftUI's gestures because a chart needs the scroll wheel, and
/// `scrollWheel(with:)` is the only way to read one: SwiftUI has a magnify gesture and no scroll
/// gesture outside a `ScrollView`, and wrapping a fixed size `Canvas` in a `ScrollView` would
/// hand the scrolling to a machine that knows nothing about the camera's clamps. Both events
/// land in one view here, which also means the double click that resets is read in the same
/// place as the gestures it undoes.
///
/// Double click is the way back to the whole world. It is what every map on this machine does,
/// it needs no control printed on a chart whose whole argument is uncluttered paper, and unlike
/// a keyboard shortcut it is found by the hand already on the trackpad. The footer says so in
/// words, because a gesture nobody is told about is a gesture nobody uses.
private struct ChartGestures: NSViewRepresentable {
    @Binding var camera: SeaChartCamera
    let sheet: CGRect
    let world: CGRect
    let tips: [(name: String, rect: CGRect)]

    func makeNSView(context: Context) -> ChartEventView {
        let view = ChartEventView()
        view.apply(sheet: sheet, world: world, camera: camera, tips: tips) { camera = $0 }
        return view
    }

    func updateNSView(_ view: ChartEventView, context: Context) {
        view.apply(sheet: sheet, world: world, camera: camera, tips: tips) { camera = $0 }
    }
}

private final class ChartEventView: NSView, NSViewToolTipOwner {
    private var sheet: CGRect = .zero
    private var world: CGRect = .zero
    private var camera: SeaChartCamera = .whole
    private var tips: [(name: String, rect: CGRect)] = []
    private var change: (SeaChartCamera) -> Void = { _ in }

    override var isFlipped: Bool { true }

    func apply(
        sheet: CGRect, world: CGRect, camera: SeaChartCamera,
        tips: [(name: String, rect: CGRect)],
        change: @escaping (SeaChartCamera) -> Void
    ) {
        self.sheet = sheet
        self.world = world
        self.camera = camera
        self.change = change
        let moved = tips.count != self.tips.count
            || zip(tips, self.tips).contains { $0.0.rect != $0.1.rect || $0.0.name != $0.1.name }
        self.tips = tips
        // Rebuilt only when a mark actually moves, because this runs on every camera change and
        // tearing down every tool tip rect sixty times a second cancels the one being shown.
        if moved {
            removeAllToolTips()
            for (index, tip) in tips.enumerated() {
                addToolTip(tip.rect, owner: self, userData: UnsafeMutableRawPointer(bitPattern: index + 1))
            }
        }
    }

    func view(
        _ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint, userData: UnsafeMutableRawPointer?
    ) -> String {
        let index = Int(bitPattern: userData) - 1
        return tips.indices.contains(index) ? tips[index].name : ""
    }

    /// Where the pointer is in the world's unit square, so a pinch can pin the water under the
    /// fingers. Off the sheet it falls back to the middle, which is what an event arriving from
    /// the margin should mean.
    private func unitPoint(for event: NSEvent) -> (x: Double, y: Double) {
        guard world.width > 0, world.height > 0 else { return (0.5, 0.5) }
        let local = convert(event.locationInWindow, from: nil)
        return ((local.x - world.minX) / world.width, (local.y - world.minY) / world.height)
    }

    override func scrollWheel(with event: NSEvent) {
        guard world.width > 0 else { return super.scrollWheel(with: event) }
        // A pinch on a mouse wheel is a wheel with a modifier, which is the convention every
        // map keeps, so the wheel pans and the wheel under command zooms.
        if event.modifierFlags.contains(.command) {
            let factor = 1 + event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.006 : 0.06)
            let anchor = unitPoint(for: event)
            change(camera.zoomed(by: factor, aroundUnitX: anchor.x, unitY: anchor.y))
            return
        }
        // The paper follows the fingers, so the camera moves against them.
        let step = event.hasPreciseScrollingDeltas ? 1.0 : 12.0
        change(camera.panned(
            byUnitX: -event.scrollingDeltaX * step / world.width,
            unitY: -event.scrollingDeltaY * step / world.height
        ))
    }

    override func magnify(with event: NSEvent) {
        let anchor = unitPoint(for: event)
        change(camera.zoomed(by: 1 + event.magnification, aroundUnitX: anchor.x, unitY: anchor.y))
    }

    override func mouseDragged(with event: NSEvent) {
        guard world.width > 0 else { return }
        change(camera.panned(
            byUnitX: -event.deltaX / world.width, unitY: -event.deltaY / world.height
        ))
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2 else { return }
        change(.whole)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: camera.isWholeWorld ? .arrow : .openHand)
    }
}

/// The chart's inks, resolved by hand rather than through `Palette`, because parchment belongs
/// to this one window.
///
/// **Both appearances are paper.** The first version answered dark mode with a deep umber sheet,
/// and the result read as a brown void with some lines on it: the single strongest thing this
/// window says is that it is an object made of aged paper, and a dark rectangle throws that away
/// to match a window frame nobody is looking at. So the sheet stays parchment in the dark, and
/// what changes is the light falling on it. The paper drops a little in value and warms, the
/// vignette roughly doubles so the edges fall away into the room, and the inks deepen to keep
/// the same separation from a slightly darker ground. It reads as the chart under a lamp, which
/// is the only honest way a parchment object goes dark. The window's own chrome, the footer and
/// its rule, still follows the system through `Palette`, so the app is not fighting the setting.
private struct ChartInk {
    let paper: Color
    let water: Color
    let land: Color
    let ink: Color
    let mark: Color
    let label: Color
    let shade: Color
    let vignette: Double
    /// How much of the paper's own surface the light picks out. The sheet is the same sheet in
    /// both appearances, but a dimmer lamp shows less of its tooth, so the texture comes back a
    /// little in the dark rather than staying at full strength over a darker ground.
    let texture: Double

    static func resolve(_ scheme: ColorScheme) -> ChartInk {
        scheme == .dark
            ? ChartInk(
                paper: chartColor(0xCDB68B),
                water: chartColor(0xC9B589),
                land: chartColor(0xB59A66),
                ink: chartColor(0x2E2213),
                mark: chartColor(0x8A2E1C),
                label: chartColor(0x2A1E10),
                shade: chartColor(0x35240F),
                vignette: 0.42,
                texture: 0.82
            )
            : ChartInk(
                paper: chartColor(0xEAE0C2),
                water: chartColor(0xE6DABA),
                land: chartColor(0xD6C494),
                ink: chartColor(0x4A3822),
                mark: chartColor(0x9E3826),
                label: chartColor(0x3D2D19),
                shade: chartColor(0x6B5228),
                vignette: 0.16,
                texture: 1.0
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
