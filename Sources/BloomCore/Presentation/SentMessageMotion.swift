import Foundation

/// A short transcript cannot scroll a new bubble out from under the composer. The bubble must
/// travel the remaining gap itself. A full transcript already puts it at or below that edge.
public enum SentMessageMotion {
    public static func distance(rowTop: Double, viewportBottom: Double, composerClearance: Double) -> Double {
        max(0, viewportBottom - max(0, composerClearance) - rowTop)
    }
}
