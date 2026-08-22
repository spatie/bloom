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
    public static func place(
        marks: [(x: Double, y: Double)],
        sizes: [(width: Double, height: Double)],
        markRadius: Double,
        boundsX: Double, boundsY: Double, boundsWidth: Double, boundsHeight: Double
    ) -> [SeaChartLabel] {
        var placed: [SeaChartLabel] = []
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
