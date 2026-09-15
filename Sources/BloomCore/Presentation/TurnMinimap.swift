import Foundation

/// The strip of marks beside a long conversation, one per prompt, that a reader points at to see
/// what was asked and clicks to go there.
///
/// **Marks are spaced by turn, not by where the turn sits in the document.** Placing them by
/// position would need the height of every row, and the transcript only measures the rows it has
/// drawn: a conversation of a thousand rows has a few dozen of them measured at any moment. A turn
/// that ran for an hour and one that was a single sentence take the same step, which is also what
/// makes a mark easy to hit.
///
/// **Only where it fits beside the text.** The column is `conversationMeasure` wide and centred, so
/// a wide pane has margins with nothing in them and a narrow one does not. Laid over prose, a mark
/// is something to click by accident in the middle of selecting a sentence.
public struct TurnMinimap: Equatable, Sendable {
    /// Below this, the whole conversation is on one or two screens and a map of it tells nobody
    /// anything the scroll bar does not.
    public static let minimumTurns = 3
    /// The step between two marks when there is room for it.
    public static let preferredPitch = 8.0
    /// Tighter than this and neighbouring marks cannot be told apart by the pointer.
    public static let minimumPitch = 1.0
    /// How much pointer target the strip is, across.
    public static let width = 24.0
    /// Kept clear between the strip and the pane's edge, where the overlay scroller appears.
    public static let edgeInset = 12.0

    public let count: Int
    public let pitch: Double

    /// Nil when there are too few turns to be worth mapping, or too little height to map them in.
    public init?(turns: Int, height: Double) {
        guard turns >= Self.minimumTurns, height > 0 else { return nil }
        let pitch = min(Self.preferredPitch, height / Double(turns))
        guard pitch >= Self.minimumPitch else { return nil }
        count = turns
        self.pitch = pitch
    }

    /// How tall the run of marks is. The strip is centred in the height it was given.
    public var length: Double { pitch * Double(count) }

    /// The middle of a mark, measured from the top of the run.
    public func centre(of index: Int) -> Double {
        pitch * (Double(index) + 0.5)
    }

    /// The mark nearest a point, measured from the top of the run. Clamped, so a pointer just past
    /// either end still means the first or the last turn.
    public func index(at offset: Double) -> Int {
        min(max(Int((offset / pitch).rounded(.down)), 0), count - 1)
    }

    /// Whether a pane this wide has a margin beside the conversation the strip can sit in.
    public static func fits(paneWidth: Double, measure: Double) -> Bool {
        (paneWidth - min(paneWidth, measure)) / 2 >= width + edgeInset
    }

    /// Which turn the reader is in: the last one starting at or before the topmost row on screen.
    ///
    /// - Parameter seqs: each turn's row sequence number, ascending.
    public static func current(in seqs: [Int], topmost seq: Int) -> Int? {
        var low = 0
        var high = seqs.count
        while low < high {
            let middle = low + (high - low) / 2
            if seqs[middle] <= seq { low = middle + 1 } else { high = middle }
        }
        return low > 0 ? low - 1 : nil
    }
}
