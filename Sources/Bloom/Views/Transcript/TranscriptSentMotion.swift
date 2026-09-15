import AppKit
import BloomCore
import QuartzCore

/// The outgoing bubble's drawing moves independently of its row's layout. This also works when
/// the conversation is too short to scroll, which a scroll-only arrival never animated.
@MainActor
final class TranscriptSentMotion {
    static let animationKey = "bloom.sentMessageArrival"
    private var distances: [MessageArrival: CGFloat] = [:]

    func animate(_ content: NSView, in cell: NSView, arrival: MessageArrival) -> Bool {
        let now = Date()
        guard arrival.remaining(at: now) > 0 else { return true }
        guard let scroll = cell.enclosingScrollView,
              let table = scroll.documentView as? NSTableView,
              table.numberOfRows > 0 else { return false }
        let row = table.row(for: cell)
        guard row >= 0 else { return false }
        distances = distances.filter { $0.key.remaining(at: now) > 0 }
        let distance: CGFloat
        if let held = distances[arrival] {
            // Persistence replaces the echo with a new cell. Continue the original path and
            // clock rather than starting another animation at the handoff.
            distance = held
        } else {
            // The reserved spacer includes a reading gap above the glass. Start under the
            // glass itself, not in that gap.
            let clearance = max(0, table.rect(ofRow: table.numberOfRows - 1).height - ComposerLayout.textClearance)
            distance = SentMessageMotion.distance(
                rowTop: table.rect(ofRow: row).minY,
                viewportBottom: scroll.contentView.documentVisibleRect.maxY,
                composerClearance: clearance
            )
            distances[arrival] = distance
        }
        guard distance > 0.5 else {
            #if DEBUG
            TranscriptSentMotionTrace.record(content: content, cell: cell, arrival: arrival, distance: distance)
            #endif
            return true
        }
        content.wantsLayer = true
        guard let layer = content.layer else { return false }
        content.clipsToBounds = false
        cell.clipsToBounds = false
        cell.superview?.clipsToBounds = false
        // Text hosting is flipped while an AppKit cell need not be. Convert the displacement
        // into the host's parent coordinates so positive travel always starts below the row.
        let origin = cell.convert(NSPoint.zero, from: table)
        let displaced = cell.convert(NSPoint(x: 0, y: distance), from: table)
        let animation = CABasicAnimation(keyPath: "transform.translation.y")
        animation.fromValue = displaced.y - origin.y
        animation.toValue = 0
        animation.duration = arrival.duration
        animation.beginTime = layer.convertTime(
            CACurrentMediaTime() - max(0, now.timeIntervalSince(arrival.startedAt)), from: nil
        )
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 1 / 3, 1, 2 / 3, 1)
        layer.add(animation, forKey: Self.animationKey)
        #if DEBUG
        TranscriptSentMotionTrace.record(content: content, cell: cell, arrival: arrival, distance: distance)
        #endif
        return true
    }
}
