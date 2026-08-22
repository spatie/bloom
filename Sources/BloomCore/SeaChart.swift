import Foundation

/// The geometry of the Discovered Seas chart, kept here so every placement is a tested
/// decision rather than a hope inside a `Canvas` closure.
///
/// The chart draws itself from baked coastline data instead of asking MapKit, because MapKit
/// offers three styles and none of them is a chart: restyling it means custom tiles, custom
/// tiles mean a tile server, and this window works offline. Drawing by hand also settles the
/// framing for good. The whole world is always shown, so the camera maths that used to live in
/// `OceanMapRegion` went with the map that needed it.
///
/// The projection is equirectangular: longitude straight to x, latitude straight to y, the
/// whole world a two by one rectangle. Mercator is what a sea chart usually wears, but it
/// cannot draw the poles at all and spends a third of its height widening Greenland, which is
/// exactly the space a window that must always show everything cannot spare. Equirectangular
/// keeps every sea in the catalogue on the sheet, the Amundsen at 73 south included, and its
/// distortion reads as the flavour of an old chart rather than as a mistake.
public enum SeaChartProjection {
    /// Width over height of the projected world. A property of the projection, not a choice:
    /// 360 degrees of longitude over 180 of latitude.
    public static let aspectRatio = 2.0

    /// A coordinate projected into the unit square, x east from the antimeridian, y south from
    /// the north pole. Unit space so the view can scale one rectangle instead of threading its
    /// size through every call.
    public static func unitPoint(latitude: Double, longitude: Double) -> (x: Double, y: Double) {
        ((longitude + 180) / 360, (90 - latitude) / 180)
    }

    /// Where a sea's mark sits inside the map rectangle: its projected point, pulled in by
    /// the mark's radius when the sea lies on the sheet's very edge. The Arctic Ocean is
    /// catalogued at 90 north and the Koro Sea a fraction off the antimeridian, and drawn
    /// literally both put half an X on the neatline. A chart would nudge the mark onto the
    /// sheet rather than ink its own border, so this does too, and the tooltip follows the
    /// mark because the mark is what the pointer can find.
    public static func markPoint(
        latitude: Double, longitude: Double,
        inX x: Double, y: Double, width: Double, height: Double, inset: Double
    ) -> (x: Double, y: Double) {
        let unit = unitPoint(latitude: latitude, longitude: longitude)
        let clampedInset = min(inset, width / 2, height / 2)
        return (
            min(max(x + unit.x * width, x + clampedInset), x + width - clampedInset),
            min(max(y + unit.y * height, y + clampedInset), y + height - clampedInset)
        )
    }

    /// The largest two by one rectangle that fits the given area once the margin is kept,
    /// centred both ways. The margin is where the frame and its ticks live, so the map proper
    /// never touches the paper's edge. Degenerate sizes collapse to an empty rectangle at the
    /// centre rather than a negative one, which is the case a first layout pass hands in.
    public static func mapRect(
        fittingWidth width: Double, height: Double, margin: Double
    ) -> (x: Double, y: Double, width: Double, height: Double) {
        let availableWidth = max(0, width - margin * 2)
        let availableHeight = max(0, height - margin * 2)
        let mapWidth = min(availableWidth, availableHeight * aspectRatio)
        let mapHeight = mapWidth / aspectRatio
        return ((width - mapWidth) / 2, (height - mapHeight) / 2, mapWidth, mapHeight)
    }
}

/// The coastline, parsed once from the baked string in `SeaChartCoastData.swift`.
public enum SeaChartCoast {
    /// Every ring, already projected into the unit square. Projected at parse time because the
    /// data is only ever drawn, and drawing scales unit points anyway.
    public static let rings: [[(x: Double, y: Double)]] = parse(builtInRings)

    /// One ring per line, "longitude,latitude" vertices separated by spaces. A vertex that
    /// does not scan or sits outside the world is dropped rather than trusted, and a ring left
    /// with fewer than three vertices cannot close so it is dropped whole; the data was
    /// machine generated, but the parser treats it like the hand kept catalogue all the same.
    public static func parse(_ encoded: String) -> [[(x: Double, y: Double)]] {
        encoded.components(separatedBy: .newlines).compactMap { line in
            let ring: [(x: Double, y: Double)] = line.split(separator: " ").compactMap { pair in
                let parts = pair.split(separator: ",")
                guard parts.count == 2,
                      let longitude = Double(parts[0]), let latitude = Double(parts[1]),
                      (-90.0...90.0).contains(latitude),
                      (-180.0...180.0).contains(longitude) else { return nil }
                return SeaChartProjection.unitPoint(latitude: latitude, longitude: longitude)
            }
            return ring.count >= 3 ? ring : nil
        }
    }
}

/// Where a discovered sea's name sits beside its mark, or nowhere.
///
/// The catalogue clusters hard: seven Japanese seas within a few degrees, a dozen around the
/// Mediterranean, and at whole world scale a few degrees is a few points. Every label cannot
/// fit, so placement is a decision with losers, which is why it lives here with tests instead
/// of in the view. The rule is a chart's rule: the mark always shows, the name shows where
/// there is room, and a name that would sit on top of another is left off rather than allowed
/// to make both unreadable.
public struct SeaChartLabel: Sendable, Equatable {
    /// Index into the marks array the placement was computed for.
    public let mark: Int
    /// Origin and size of the label's box, in the same space as the marks.
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(mark: Int, x: Double, y: Double, width: Double, height: Double) {
        self.mark = mark
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    func intersects(_ other: SeaChartLabel) -> Bool {
        x < other.x + other.width && other.x < x + width
            && y < other.y + other.height && other.y < y + height
    }
}

public enum SeaChartLabels {
    /// Breathing room between a mark and its label, and between two labels. Small because the
    /// whole chart is small; the tests pin it only through behaviour.
    static let gap = 2.0

    /// Greedy placement in the order the marks arrive, which the caller keeps stable so a
    /// redraw never shuffles names. Each label tries beside its mark to the right, then left,
    /// then above, then below, and takes the first spot inside the bounds that touches no
    /// already placed label and covers no mark. A mark whose four spots are all taken gets no
    /// label at all: at this scale a colliding pair reads as neither name.
    /// `reserved` is the paper a name may not be written on: the cartouche and the compass rose
    /// are opaque, so a name allowed to land on either is simply lost, which is what happened to
    /// the Argentine Sea the first time forty seas were charted. They are handed in rather than
    /// hard coded because where they sit is the view's business and whether a name may sit there
    /// is this function's.
    public static func place(
        marks: [(x: Double, y: Double)],
        sizes: [(width: Double, height: Double)],
        markRadius: Double,
        boundsX: Double, boundsY: Double, boundsWidth: Double, boundsHeight: Double,
        reserved: [(x: Double, y: Double, width: Double, height: Double)] = []
    ) -> [SeaChartLabel] {
        var placed: [SeaChartLabel] = []
        let blocked = reserved.map {
            SeaChartLabel(mark: -1, x: $0.x, y: $0.y, width: $0.width, height: $0.height)
        }
        for (index, mark) in marks.enumerated() {
            guard index < sizes.count else { break }
            let size = sizes[index]
            let offset = markRadius + gap
            let candidates: [(Double, Double)] = [
                (mark.x + offset, mark.y - size.height / 2),
                (mark.x - offset - size.width, mark.y - size.height / 2),
                (mark.x - size.width / 2, mark.y - offset - size.height),
                (mark.x - size.width / 2, mark.y + offset),
            ]
            for (x, y) in candidates {
                let candidate = SeaChartLabel(
                    mark: index, x: x, y: y, width: size.width, height: size.height
                )
                guard x >= boundsX, y >= boundsY,
                      x + size.width <= boundsX + boundsWidth,
                      y + size.height <= boundsY + boundsHeight else { continue }
                guard !placed.contains(where: { $0.intersects(candidate) }) else { continue }
                guard !blocked.contains(where: { $0.intersects(candidate) }) else { continue }
                let coversMark = marks.enumerated().contains { otherIndex, other in
                    otherIndex != index
                        && other.x + markRadius > x && other.x - markRadius < x + size.width
                        && other.y + markRadius > y && other.y - markRadius < y + size.height
                }
                guard !coversMark else { continue }
                placed.append(candidate)
                break
            }
        }
        return placed
    }
}

/// Where the chart is looking: how far in, and at what.
///
/// Zoom lives here rather than in the view because everything interesting about it is
/// arithmetic with edge cases. A camera that can be dragged past the antimeridian shows blank
/// paper where the world should be, and a camera with no ceiling shows four coastline vertices
/// and a lot of nothing, so both ends are clamped on the way in and the clamping is what the
/// tests hold. The view is left with a gesture and a multiplication.
///
/// The state is a scale and a centre in unit space, not a rectangle, because a rectangle has
/// four numbers that can disagree with each other. Unit space rather than degrees so it composes
/// with `unitPoint` without a second conversion, and because the projection is linear in both
/// axes the same scale applies to each: one over the scale is the fraction of the world on the
/// sheet, in x and in y alike.
public struct SeaChartCamera: Sendable, Equatable {
    /// The whole world, which is the floor as well as the default. A chart that could be zoomed
    /// out further would draw the sheet as a stamp in the middle of the paper, and there is
    /// nothing beyond the world to reveal by doing it.
    public static let minimumScale = 1.0
    /// Ten times in shows about thirty degrees of longitude, which is the Japanese cluster with
    /// room for every name. Further in and the baked 110m coastline runs out of vertices before
    /// the eye runs out of curiosity, so the chart would be magnifying its own straight lines.
    public static let maximumScale = 10.0

    public let scale: Double
    public let centerX: Double
    public let centerY: Double

    /// The whole world, centred. What the window opens on and what a double click returns to.
    public static let whole = SeaChartCamera(scale: minimumScale, centerX: 0.5, centerY: 0.5)

    /// Clamps on the way in, so no other member has to. The scale is bounded first because the
    /// centre's own bounds depend on it: at scale one there is exactly one legal centre, and at
    /// ten the centre may sit anywhere from a twentieth in to nineteen twentieths.
    public init(scale: Double, centerX: Double, centerY: Double) {
        let bounded = min(max(scale.isFinite ? scale : Self.minimumScale, Self.minimumScale), Self.maximumScale)
        let half = 0.5 / bounded
        self.scale = bounded
        self.centerX = min(max(centerX.isFinite ? centerX : 0.5, half), 1 - half)
        self.centerY = min(max(centerY.isFinite ? centerY : 0.5, half), 1 - half)
    }

    /// Whether the whole world is on the sheet, which is what the reset control keys off.
    public var isWholeWorld: Bool { scale <= Self.minimumScale + 1e-9 }

    /// The part of the unit square currently on the sheet.
    public var visibleRegion: (x: Double, y: Double, width: Double, height: Double) {
        let side = 1 / scale
        return (centerX - side / 2, centerY - side / 2, side, side)
    }

    /// Zoom keeping one unit point pinned where it already is, which is what a pinch means: the
    /// water under two fingers stays under them. Zooming about the centre instead was the first
    /// try and it made a trackpad feel like it was fighting back, because the thing being aimed
    /// at slid away as it grew.
    ///
    /// The anchor is honoured before the clamp, so a pinch near the edge of the world zooms in
    /// as far as it can and then slides rather than refusing.
    public func zoomed(by factor: Double, aroundUnitX x: Double, unitY y: Double) -> SeaChartCamera {
        guard factor.isFinite, factor > 0 else { return self }
        let target = min(max(scale * factor, Self.minimumScale), Self.maximumScale)
        let before = visibleRegion
        let fractionX = before.width > 0 ? (x - before.x) / before.width : 0.5
        let fractionY = before.height > 0 ? (y - before.y) / before.height : 0.5
        let side = 1 / target
        return SeaChartCamera(
            scale: target,
            centerX: x - fractionX * side + side / 2,
            centerY: y - fractionY * side + side / 2
        )
    }

    /// Pan by a distance in unit space. Clamping falls out of the initialiser, so a scroll that
    /// runs off the world stops at the world's edge rather than wrapping or drifting.
    public func panned(byUnitX x: Double, unitY y: Double) -> SeaChartCamera {
        SeaChartCamera(scale: scale, centerX: centerX + x, centerY: centerY + y)
    }
}

extension SeaChartProjection {
    /// Where the whole world sits once the camera is applied, in the same space as the sheet.
    ///
    /// Zoom is expressed as a bigger world behind a fixed window rather than as a transform on
    /// the drawing, because every placement in this file already takes a rectangle and works in
    /// unit space inside it. Handing them a rectangle larger than the sheet is the whole of the
    /// change: coastlines, marks and labels all zoom without knowing that zoom exists, and the
    /// label placer gets the sheet as its bounds, so a name dropped at whole world scale is
    /// reconsidered the moment the crowd around it spreads out.
    ///
    /// The result is deliberately not clamped to the sheet. It is meant to overhang; the view
    /// clips.
    public static func worldRect(
        inX x: Double, y: Double, width: Double, height: Double, camera: SeaChartCamera
    ) -> (x: Double, y: Double, width: Double, height: Double) {
        let worldWidth = width * camera.scale
        let worldHeight = height * camera.scale
        return (
            x + width / 2 - camera.centerX * worldWidth,
            y + height / 2 - camera.centerY * worldHeight,
            worldWidth,
            worldHeight
        )
    }
}

extension SeaChartLabels {
    /// How big a sea's name is drawn, given how wide the sheet is.
    ///
    /// It was a flat 9.5 points and unreadable. A name on a chart is the thing the chart is for,
    /// so it grows with the paper: a window filling most of a large display has several times the
    /// room the 480 point minimum has, and spending none of it on legibility was the mistake.
    ///
    /// The floor is where "Ligurian Sea" is still comfortable at the smallest window the view
    /// allows, and the ceiling is where a name starts to compete with the coastline it sits on.
    /// Between them it tracks the sheet's width, which is the only measure that matters: a taller
    /// window does not make a two by one chart any wider.
    ///
    /// Growing the type costs names. Placement drops a label whose four candidate boxes are all
    /// taken, and a wider box collides sooner, so the seven seas around Japan lose more of their
    /// names at whole world scale than they did at 9.5 points. That is the trade taken on
    /// purpose: an unreadable name and a dropped name are worth the same, and zoom now buys the
    /// dropped ones back.
    public static func fontSize(forMapWidth width: Double) -> Double {
        min(max(width / 62, 11.5), 19)
    }
}

extension SeaChartProjection {
    /// The size the window should open at on a screen of the given working area.
    ///
    /// Eight tenths of the screen is the brief, but eight tenths of both dimensions is not what
    /// it should mean here. The chart is two by one and always will be, so on a very wide or
    /// very tall screen that rectangle would open with a band of blank paper down one pair of
    /// sides that no content will ever reach. So the fraction is a budget rather than a shape:
    /// the largest sheet that fits inside it is found first, and the window is then cut to that
    /// sheet plus its margins and its footer. The window that opens is filled edge to edge.
    ///
    /// It stays only a starting size. Once a window has a frame of its own, that frame wins, and
    /// nothing here is applied again.
    public static func defaultWindowSize(
        screenWidth: Double, screenHeight: Double,
        margin: Double, footerHeight: Double, fraction: Double = 0.8
    ) -> (width: Double, height: Double) {
        let budgetWidth = max(0, screenWidth * fraction)
        let budgetHeight = max(0, screenHeight * fraction)
        let sheet = mapRect(
            fittingWidth: budgetWidth,
            height: max(0, budgetHeight - footerHeight),
            margin: margin
        )
        return (
            max(480, sheet.width + margin * 2),
            max(360, sheet.height + margin * 2 + footerHeight)
        )
    }
}
