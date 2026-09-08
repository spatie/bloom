/// Fold analysis owned by a conversation, so returning to it does not scan its history again.
/// Invalidating a changed row also covers results and permission decisions that append no row.
public struct TranscriptFoldCache: Sendable {
    private var held = TranscriptFold.Folds.none
    private var dirty = true

    public init() {}

    public mutating func reset() {
        held = .none
        dirty = true
    }

    public mutating func invalidate(row index: Int) {
        // The fold scanner only revisits the current turn. An older row changing invalidates
        // that settled prefix too, so the uncommon late-result case must start from scratch.
        if index < held.resumeIndex { held = .none }
        dirty = true
    }

    public mutating func resolve<Facts: RandomAccessCollection>(
        _ facts: Facts
    ) -> TranscriptFold.Folds where Facts.Element == TranscriptFold.Fact, Facts.Index == Int {
        guard dirty || held.scannedRows != facts.count else { return held }
        held = TranscriptFold.folds(in: facts, extending: held)
        dirty = false
        return held
    }
}
