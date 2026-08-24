import CoreGraphics
import Foundation

/// One branch leaving a spine and rejoining it, as a polyline.
///
/// The runbloom.app hero draws a git history: a horizontal `main` with worktrees curving away
/// from it, running for a while, and curving back. `BrandBranching` on the welcome window draws
/// the same figure, and this is the shape of it, here rather than in the view because
/// `Tests/BloomCoreTests` cannot reach a view and a curve that comes back to the wrong height is
/// exactly the sort of arithmetic that goes wrong silently. What the view owns is colour, timing
/// and the render server; what this owns is where the line goes.
///
/// The site samples its cubics with `sampleCubic` at a fixed step and then measures the polyline
/// to place things along it. The same two jobs are `shape` and `paced` below, and they are
/// separate because they answer different questions: `shape` is the line, `paced` is how fast a
/// light travelling it should be at any moment. A keyframe animation interpolates its values on
/// even key times, so a light handed the raw samples would race through the tight curves at the
/// ends and dawdle along the run; handed the paced ones it holds one speed the whole way.
public enum BranchCurve {
    /// The branch, from `from` to `to` on the x axis, both ends on `spine`.
    ///
    /// `rise` is how far the run sits off the spine, signed, so a caller asks for a branch above
    /// or below by its sign alone. `crown` bows the run further out at its middle, in the same
    /// direction as the rise: a dead straight run reads as a lane on a diagram, and a run with a
    /// few points of camber in it reads as a swell, which is the whole reason this is on a
    /// welcome screen rather than in a figure.
    public static func shape(
        from: CGFloat,
        to: CGFloat,
        spine: CGFloat,
        rise: CGFloat,
        crown: CGFloat = 0,
        samples: Int = 20
    ) -> [CGPoint] {
        let span = to - from
        guard span > 0, samples > 0 else { return [CGPoint(x: from, y: spine)] }

        // How much x the departure spends turning.
        //
        // The site's quarter of the span, with a floor under it that is most of the rise. A turn
        // measured only across the branch is a hook on a tall one and a long lazy sweep on a flat
        // one, because the climb it has to make is not in the number at all. Taking the larger of
        // the two makes every branch leave the spine at about the same angle, which is what makes
        // four of them at four heights read as one family. The ceiling keeps the two turns from
        // meeting in the middle and inverting the run on a short branch.
        let lead = min(max(span * 0.26, abs(rise) * 0.9), span * 0.42)
        let lane = spine + rise
        let camber = lane + (rise < 0 ? -crown : crown)
        let runStart = from + lead
        let runEnd = to - lead

        var points = curve(
            CGPoint(x: from, y: spine),
            CGPoint(x: from + lead * 0.62, y: spine),
            CGPoint(x: from + lead * 0.34, y: lane),
            CGPoint(x: runStart, y: lane),
            samples: samples
        )
        points += curve(
            CGPoint(x: runStart, y: lane),
            CGPoint(x: runStart + (runEnd - runStart) * 0.32, y: camber),
            CGPoint(x: runEnd - (runEnd - runStart) * 0.32, y: camber),
            CGPoint(x: runEnd, y: lane),
            samples: samples
        ).dropFirst()
        points += curve(
            CGPoint(x: runEnd, y: lane),
            CGPoint(x: to - lead * 0.34, y: lane),
            CGPoint(x: to - lead * 0.62, y: spine),
            CGPoint(x: to, y: spine),
            samples: samples
        ).dropFirst()

        return points
    }

    /// The same line, resampled so every step along it is the same distance.
    ///
    /// Returns `count` points, the first and last of them the ends of the input.
    public static func paced(_ points: [CGPoint], count: Int) -> [CGPoint] {
        guard count > 1, points.count > 1 else { return points }

        let lengths = cumulativeLengths(points)
        guard let total = lengths.last, total > 0 else { return points }

        var walked = 1
        return (0..<count).map { step in
            let target = total * CGFloat(step) / CGFloat(count - 1)
            while walked < lengths.count - 1, lengths[walked] < target { walked += 1 }
            let before = lengths[walked - 1]
            let after = lengths[walked]
            let ratio = after > before ? (target - before) / (after - before) : 0
            let start = points[walked - 1]
            let end = points[walked]
            return CGPoint(
                x: start.x + (end.x - start.x) * ratio,
                y: start.y + (end.y - start.y) * ratio
            )
        }
    }

    /// How long the polyline is, end to end.
    public static func length(of points: [CGPoint]) -> CGFloat {
        cumulativeLengths(points).last ?? 0
    }

    private static func cumulativeLengths(_ points: [CGPoint]) -> [CGFloat] {
        var lengths: [CGFloat] = [0]
        lengths.reserveCapacity(points.count)
        for index in 1..<max(points.count, 1) {
            let step = hypot(
                points[index].x - points[index - 1].x,
                points[index].y - points[index - 1].y
            )
            lengths.append(lengths[index - 1] + step)
        }
        return lengths
    }

    private static func curve(
        _ from: CGPoint,
        _ first: CGPoint,
        _ second: CGPoint,
        _ to: CGPoint,
        samples: Int
    ) -> [CGPoint] {
        (0...samples).map { step in
            let t = CGFloat(step) / CGFloat(samples)
            let inverse = 1 - t
            let a = inverse * inverse * inverse
            let b = 3 * inverse * inverse * t
            let c = 3 * inverse * t * t
            let d = t * t * t
            return CGPoint(
                x: a * from.x + b * first.x + c * second.x + d * to.x,
                y: a * from.y + b * first.y + c * second.y + d * to.y
            )
        }
    }
}
